import Foundation
import AppKit
import Network
import UniformTypeIdentifiers
#if canImport(CrossDropCore)
import CrossDropCore
#endif

enum AppTab: String, CaseIterable, Identifiable {
    case send, receive, devices, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .send: return "Send"
        case .receive: return "Receive"
        case .devices: return "Devices"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .send: return "paperplane"
        case .receive: return "tray.and.arrow.down"
        case .devices: return "checkmark.shield"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct SelectedFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    /// Folders above the file inside a dropped folder, outermost first (§9.1).
    var path: [String] = []

    var displayName: String { (path + [name]).joined(separator: "/") }
}

/// Who can send to this Mac (AirDrop-style).
enum ReceiveMode: String, CaseIterable, Identifiable {
    /// Paired devices only; invisible to everyone else (§9.5).
    case mine
    case everyone
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mine: return "My Devices"
        case .everyone: return "Everyone"
        case .off: return "Off"
        }
    }
}

/// A link or text waiting to be sent (§9.2).
struct PendingText: Equatable {
    let kind: OfferKind
    let text: String

    /// A lone http(s) URL becomes a link; other text up to the protocol limit stays text.
    static func from(_ raw: String) -> PendingText? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, Int64(text.utf8.count) <= ProtocolConstants.maxTextPayload else { return nil }
        let lower = text.lowercased()
        let isLink = text.count <= 2048 && !text.contains(where: { $0.isWhitespace })
            && (lower.hasPrefix("https://") || lower.hasPrefix("http://")) && URL(string: text)?.host != nil
        return PendingText(kind: isLink ? .link : .text, text: text)
    }
}

/// Thread-safe flag the engine reads on its own threads.
final class AtomicFlag {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

enum ReceiverStatus: Equatable {
    case off
    case starting
    case ready
    case noNetwork
    case localNetworkDenied
    case failed(String)
}

enum DiscoveryStatus: Equatable {
    case idle
    case browsing
    case noNetwork
    case localNetworkDenied
    case failed(String)
}

enum PromptItem: Identifiable {
    case pairing(PairingPrompt, Decision)
    case offer(OfferPrompt, Decision)

    var id: String {
        switch self {
        case .pairing(let prompt, _): return "pair-" + prompt.id
        case .offer(let offer, _): return "offer-" + offer.transferId
        }
    }

    var decision: Decision {
        switch self {
        case .pairing(_, let decision), .offer(_, let decision): return decision
        }
    }
}

struct Notice: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// An optional button on the toast; run it with `AppModel.performNoticeAction(_:)`.
    var action: NoticeAction? = nil
}

/// What the button on a toast does.
enum NoticeAction: Equatable {
    /// Show these files in Finder.
    case reveal([URL])
    /// Switch receiving to "My Devices" (needed for answers from the phone).
    case useMyDevices
    /// Keep a failed send and deliver it when the device is back (transfer id).
    case sendWhenNearby(String)

    var title: String {
        switch self {
        case .reveal: return "Show in Finder"
        case .useMyDevices: return "Use My Devices"
        case .sendWhenNearby: return "Send When Nearby"
        }
    }
}

/// "Take Photo / Pick Photo with <phone>" (§9.7): the request this Mac sent and is waiting on.
struct CaptureState: Equatable {
    enum Phase: Equatable {
        /// Receiving is Off, so the phone has nowhere to send the photo.
        case needsReceiving
        /// Connecting and asking the phone.
        case asking
        /// The phone said yes; waiting for the photo to arrive.
        case waiting
        case failed(String)
    }

    let id = UUID()
    let kind: CaptureKind
    let deviceId: String
    let deviceName: String
    var requestId: String?
    var phase: Phase
    let startedAt: Date

    var isActive: Bool { phase == .asking || phase == .waiting }

    var title: String {
        kind == .photo ? "Take Photo with \(deviceName)" : "Pick Photo from \(deviceName)"
    }

    var statusText: String {
        switch phase {
        case .needsReceiving:
            return "Receiving is Off, so \(deviceName) can't send the photo back. Switch to My Devices to allow it."
        case .asking: return "Asking \(deviceName)…"
        case .waiting:
            return kind == .photo ? "Take the photo on \(deviceName). It comes straight to your clipboard."
                                  : "Pick a photo on \(deviceName). It comes straight to your clipboard."
        case .failed(let message): return message
        }
    }
}

/// How long a Drip Room lasts (§9.9: at most 4 hours).
enum RoomDuration: Int64, CaseIterable, Identifiable {
    case thirtyMinutes = 1800
    case oneHour = 3600
    case twoHours = 7200
    case fourHours = 14400

    var id: Int64 { rawValue }

    var title: String {
        switch self {
        case .thirtyMinutes: return "30 min"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fourHours: return "4 hours"
        }
    }
}

/// A transfer as shown in the UI, with a smoothed rate.
struct TransferItem: Identifiable {
    var snapshot: TransferSnapshot
    var bytesPerSecond: Double?
    var transferStartedAt: TimeInterval?
    private var sampleBytes: Int64 = 0
    private var sampleTime: TimeInterval = 0

    var id: String { snapshot.id }

    init(_ snapshot: TransferSnapshot, now: TimeInterval) {
        self.snapshot = snapshot
        update(snapshot, now: now)
    }

    mutating func update(_ snapshot: TransferSnapshot, now: TimeInterval) {
        let bytes = snapshot.bytesTransferred
        if snapshot.phase == .transferring {
            if transferStartedAt == nil {
                transferStartedAt = now
                sampleBytes = bytes
                sampleTime = now
            }
            let elapsed = now - sampleTime
            if elapsed >= 0.5 {
                let instant = Double(max(0, bytes - sampleBytes)) / elapsed
                bytesPerSecond = bytesPerSecond.map { $0 * 0.7 + instant * 0.3 } ?? instant
                sampleBytes = bytes
                sampleTime = now
            }
        } else if snapshot.phase.isFinished {
            bytesPerSecond = nil
        }
        self.snapshot = snapshot
    }

    var fraction: Double {
        let total = snapshot.totalBytes
        guard total > 0 else { return snapshot.phase == .completed ? 1 : 0 }
        return min(1, Double(snapshot.bytesTransferred) / Double(total))
    }

    /// Seconds left, only once the estimate is meaningful.
    func remainingSeconds(now: TimeInterval) -> Double? {
        guard snapshot.phase == .transferring, let rate = bytesPerSecond, rate > 1,
              let started = transferStartedAt, now - started >= 2 else { return nil }
        let remaining = Double(snapshot.totalBytes - snapshot.bytesTransferred) / rate
        return remaining >= 3 ? remaining : nil
    }
}

/// What it takes to send a transfer again (Retry, Send When Nearby).
struct RetryInfo {
    let files: [OutgoingFile]
    let deviceId: String
    let deviceName: String
    let platform: String
    let kind: OfferKind
    let text: String?
    let expiresAfter: Int64?
}

/// Per-send choices that are not part of the selection itself.
struct SendOptions {
    /// §9.8: ask the receiver to delete the files this long after arrival.
    var expiresAfter: Int64? = nil
    /// Clipboard offers: no card, no history entry, no celebration.
    var quiet = false
    /// Delivering this queued send.
    var queueId: UUID? = nil
}

/// App state. Mutated on the main thread only; engine callbacks hop to main.
final class AppModel: ObservableObject, CrossDropDelegate {
    static let shared = AppModel()

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    // Receiving and discovery
    @Published private(set) var receivingEnabled: Bool
    @Published private(set) var receiveMode: ReceiveMode
    @Published private(set) var receiverStatus: ReceiverStatus = .off
    @Published private(set) var discoveryStatus: DiscoveryStatus = .idle
    @Published private(set) var nearby: [DiscoveredDevice] = []
    @Published private(set) var networkAvailable = true

    // Sending
    @Published var selectedFiles: [SelectedFile] = []
    @Published var selectedDeviceId: String?
    /// A link or text to send instead of files.
    @Published var pendingText: PendingText?
    /// "Send to several": devices ticked for one send.
    @Published var multiSelecting = false
    @Published var multiSelection: Set<String> = []
    @Published private(set) var transfers: [TransferItem] = []

    // Prompts
    @Published private(set) var prompts: [PromptItem] = []
    @Published private(set) var waitingPairingIds: Set<String> = []

    // Stored data
    @Published private(set) var trustedDevices: [TrustedDeviceRecord] = []
    @Published private(set) var history: [HistoryEntry] = []

    // Settings
    @Published private(set) var deviceName: String
    @Published private(set) var destination: URL
    @Published private(set) var autoOffMinutes: Int
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var autoOffDate: Date?
    @Published private(set) var soundOnDone: Bool
    @Published private(set) var heicToJpeg: Bool
    /// Port the receiver listens on, once ready (shown in the pairing QR code).
    @Published private(set) var listeningPort: UInt16?
    /// The "Pair a phone" QR sheet.
    @Published var showingPairSheet = false

    // UI
    @Published var selectedTab: AppTab = .send
    @Published var notice: Notice?
    /// The "All done!" moment shown briefly after a transfer is verified.
    @Published var celebration: Celebration?
    @Published private(set) var windowRequest = 0

    // Shelf ("Pocket"): files stashed for later, kept across launches (paths only).
    @Published private(set) var shelf: [ShelfItem] = []
    /// Shelf items whose file is no longer there. Checked when the Shelf changes and when
    /// CrossDrop comes to the front, never while views redraw.
    @Published private(set) var missingShelfIds: Set<UUID> = []

    // Send when nearby: sends waiting for a paired device to come back.
    @Published private(set) var sendQueue: [QueuedSend] = []
    /// Queued sends being delivered right now.
    @Published private(set) var deliveringQueueIds: Set<UUID> = []

    // Take Photo / Pick Photo with the phone (§9.7).
    @Published private(set) var capture: CaptureState?

    // Drip Rooms (§9.9). One room at a time, hosted by this Mac or joined from an invite.
    @Published private(set) var currentRoom: Room?
    @Published private(set) var roomIsHosted = false
    /// The "Start a Drip Room" sheet (name, duration, then the room's QR code).
    @Published var showingRoomSheet = false

    // Expiring drops (§9.8): received files waiting to go to the Trash.
    @Published private(set) var expiringFiles: [ExpiringFile] = []

    // Settings added with the island, shelf and friends.
    /// Drip Island while dragging files (on by default).
    @Published private(set) var dripIslandEnabled: Bool
    /// "Offer what I copy to my phone" (off by default).
    @Published private(set) var offerClipboardToPhone: Bool
    /// What happened to the last copied text, for the setting's footnote ("Sent to Pixel at 10:42").
    @Published private(set) var clipboardOfferStatus: String?
    /// Smart arrival: "Sort by type" (off by default).
    @Published private(set) var sortByType: Bool
    /// Turbo (experimental): parallel connections for multi-file sends (off by default).
    @Published private(set) var turboEnabled: Bool
    /// Sender option for the next send of files: "Auto-delete on arrival after 24 h".
    /// Resets after each send so it never sticks by surprise.
    @Published var autoDeleteNextSend = false

    let identity: DeviceIdentity
    let identityLocation: IdentityStore.Location
    let trustStore = TrustStore()
    private let historyStore = HistoryStore()

    private var server: CrossDropServer?
    /// Read by the engine on its own threads: refuse unpaired devices (§9.5).
    private let privateFlag = AtomicFlag(false)
    /// Try a stable port first so paired phones can reach this Mac at its last address.
    private var usePreferredPort = true
    private var discovered: [DiscoveredDevice] = []
    private lazy var browser: BonjourBrowser = makeBrowser()
    private var discoveryClients = 0
    private var outgoing: [String: OutgoingTransfer] = [:]
    private var retryInfo: [String: RetryInfo] = [:]
    /// Link / text sent per transfer id, kept for history ("Send again" for links).
    private var sentText: [String: String] = [:]
    private var recordedIds: Set<String> = []
    private var autoOffTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var networkSignature: String?
    private var started = false

    /// Drip Rooms this Mac is in, shared by its receiver and its senders (§9.9).
    let rooms = Rooms()
    private let shelfFile = JSONListFile<ShelfItem>(name: "shelf.json")
    private let queueFile = JSONListFile<QueuedSend>(name: "send-queue.json")
    private let expiringFile = JSONListFile<ExpiringFile>(name: "expiring-files.json")
    private let clipboardWatcher = ClipboardWatcher()
    /// Clipboard sends: no card, no history, no celebration.
    private var quietIds: Set<String> = []
    /// Transfer id → queued send it delivers.
    private var queueAttempts: [String: UUID] = [:]
    /// Queue attempts that got far enough to show a card (past connecting).
    private var shownQueueAttempts: Set<String> = []
    private var captureTimer: Timer?
    /// "Take Photo" asked while the receiver was still starting: sent once it is ready.
    private var captureAfterReady: (kind: CaptureKind, deviceId: String)?
    private var roomTimer: Timer?
    private var trustPurgeTimer: Timer?
    private var expiryTimer: Timer?
    /// Where files moved after arrival (old path → new location), for "Show in Finder" on cards.
    private var relocated: [String: URL] = [:]
    private var activeObserver: NSObjectProtocol?
    /// Silent sends (clipboard, queue) → the device they were started for. Another device
    /// answering at that address stops the send (best effort; see `wrongPeer(_:)`).
    private var expectedPeers: [String: String] = [:]
    /// Shown queue attempts that failed but stay queued (transfer id → queued send), so
    /// their card offers neither Retry nor Send When Nearby (that would send twice).
    private var keptQueueAttempts: [String: UUID] = [:]

    private init() {
        let loaded = IdentityStore.loadOrCreate()
        identity = loaded.0
        identityLocation = loaded.1
        let mode = ReceiveMode(rawValue: AppSettings.receiveMode) ?? .everyone
        receiveMode = mode
        receivingEnabled = mode != .off
        heicToJpeg = AppSettings.heicToJpeg
        dripIslandEnabled = AppSettings.dripIsland
        offerClipboardToPhone = AppSettings.offerClipboard
        sortByType = AppSettings.sortByType
        turboEnabled = AppSettings.turbo
        deviceName = AppSettings.deviceName
        destination = AppSettings.destination
        autoOffMinutes = AppSettings.autoOffMinutes
        notificationsEnabled = AppSettings.notificationsEnabled
        soundOnDone = AppSettings.soundOnDone
        trustStore.purgeExpired()
        // Rooms don't survive a relaunch (they live in memory), so neither does the
        // temporary trust their members got: nothing here could end it early otherwise.
        trustStore.forgetTemporary()
        trustedDevices = trustStore.all
        history = historyStore.entries
        shelf = shelfFile.load()
        missingShelfIds = Self.missingIds(in: shelf)
        sendQueue = queueFile.load()
        expiringFiles = expiringFile.load()
        trustStore.onChange = { [weak self] list in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let before = Set(self.trustedDevices.map(\.deviceId))
                self.trustedDevices = list
                self.refreshNearby()
                self.scheduleTrustPurge()
                // A new pairing while the QR sheet is up: that's the phone that scanned it.
                if self.showingPairSheet, let added = list.first(where: { !before.contains($0.deviceId) }) {
                    self.showingPairSheet = false
                    self.show("Paired with \(added.name).")
                }
            }
        }
        privateFlag.set(mode == .mine)
        clipboardWatcher.onText = { [weak self] text in self?.offerCopiedText(text) }
    }

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        NotificationManager.shared.onOpen = { [weak self] in self?.requestMainWindow() }
        NotificationManager.shared.onOfferAction = { [weak self] transferId, accept in
            guard let self = self, let prompt = self.prompts.first(where: { $0.id == "offer-" + transferId }) else { return }
            self.respond(to: prompt, accept: accept)
        }
        NotificationManager.shared.onReveal = { [weak self] urls in self?.reveal(urls) }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.refreshShelfPresence()
        }
        startPathMonitor()
        if receivingEnabled { startServer() }
        refreshNearby()
        scheduleTrustPurge()
        checkExpiringFiles()
        // Queued sends get one direct try at the paired device's last address after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.deliverQueue() }
    }

    private var localInfo: LocalInfo {
        LocalInfo(name: deviceName, platform: "macos", appVersion: Self.appVersion)
    }

    // MARK: - Receiving

    /// On: visible to everyone. Off: nobody can send.
    func setReceiving(_ enabled: Bool) {
        setReceiveMode(enabled ? .everyone : .off)
    }

    func setReceiveMode(_ mode: ReceiveMode) {
        guard mode != receiveMode else { return }
        let wasOff = receiveMode == .off
        receiveMode = mode
        receivingEnabled = mode != .off
        AppSettings.receiveMode = mode.rawValue
        privateFlag.set(mode == .mine)
        if mode == .off {
            stopServer()
            receiverStatus = .off
            return
        }
        if wasOff, notificationsEnabled { NotificationManager.shared.requestAuthorization { _ in } }
        if wasOff || server == nil {
            startServer()
        } else {
            // Same listener (transfers in progress keep going); only the announcement changes.
            server?.refreshAdvertisement()
            scheduleAutoOff()
        }
    }

    private func startServer() {
        stopServer()
        guard receivingEnabled else {
            receiverStatus = .off
            return
        }
        guard networkAvailable else {
            receiverStatus = .noNetwork
            return
        }
        let flag = privateFlag
        let server = CrossDropServer(configuration: .init(
            identity: identity, local: localInfo, trust: trustStore,
            destination: { AppSettings.destination }, privateMode: { flag.get() },
            rooms: rooms, turbo: { true }))
        server.delegate = self
        // A photo request still waiting keeps working with the new listener (§9.7).
        if let pending = capture, pending.phase == .waiting, let requestId = pending.requestId {
            let left = ProtocolConstants.captureRequestTTL - Date().timeIntervalSince(pending.startedAt)
            if left > 0 { server.captureRequests.expect(requestId, deviceId: pending.deviceId, ttl: left) }
        }
        server.onStateChange = { [weak self, weak server] state in
            DispatchQueue.main.async {
                guard let self = self, let server = server, self.server === server else { return }
                self.apply(state)
            }
        }
        do {
            try server.start(port: usePreferredPort ? Self.preferredPort : nil, advertise: true)
            self.server = server
            receiverStatus = .starting
        } catch {
            receiverStatus = .failed("Couldn't start listening.")
        }
        scheduleAutoOff()
    }

    static let preferredPort: UInt16 = 47100

    private func stopServer() {
        server?.stop()
        server = nil
        listeningPort = nil
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDate = nil
    }

    private func apply(_ state: CrossDropServer.State) {
        switch state {
        case .stopped: receiverStatus = receivingEnabled ? .starting : .off
        case .starting: receiverStatus = .starting
        case .ready(let port):
            receiverStatus = .ready
            listeningPort = port
            if let pending = captureAfterReady {
                captureAfterReady = nil
                launchPendingCapture(pending.kind, deviceId: pending.deviceId)
            }
        case .localNetworkDenied:
            receiverStatus = .localNetworkDenied
            if captureAfterReady != nil {
                captureFailed("Allow Local Network access for CrossDrop in System Settings, then ask again.")
            }
        case .failed:
            if usePreferredPort {
                // The stable port is taken (another app, or a second copy): any free port works too.
                usePreferredPort = false
                startServer()
                return
            }
            receiverStatus = .failed("Receiving stopped unexpectedly.")
            if captureAfterReady != nil {
                captureFailed("Receiving couldn't start, so the phone has nowhere to send the photo.")
            }
        }
    }

    private func scheduleAutoOff() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDate = nil
        // Only "Everyone" times out; "My devices" stays on (it is invisible to others).
        guard receiveMode == .everyone, autoOffMinutes > 0 else { return }
        let date = Date().addingTimeInterval(TimeInterval(autoOffMinutes * 60))
        autoOffDate = date
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            self?.autoOffFired()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoOffTimer = timer
    }

    private func autoOffFired() {
        let busy = transfers.contains { $0.snapshot.direction == .incoming && !$0.snapshot.phase.isFinished }
        if busy {
            let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in self?.autoOffFired() }
            RunLoop.main.add(timer, forMode: .common)
            autoOffTimer = timer
            return
        }
        setReceiveMode(.mine)
        show("No longer visible to everyone. Your paired devices can still send.")
    }

    // MARK: - Discovery

    private func makeBrowser() -> BonjourBrowser {
        let browser = BonjourBrowser(ownDeviceId: identity.deviceId)
        browser.onDevicesChanged = { [weak self] devices in
            DispatchQueue.main.async { self?.updateNearby(devices) }
        }
        browser.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch state {
                case .idle: self.discoveryStatus = .idle
                case .browsing: self.discoveryStatus = .browsing
                case .localNetworkDenied: self.discoveryStatus = .localNetworkDenied
                case .failed: self.discoveryStatus = .failed("Couldn't look for nearby devices.")
                }
            }
        }
        return browser
    }

    /// Views that show nearby devices call this on appear / disappear so the
    /// browser only runs while someone is looking.
    func beginDiscovery() {
        discoveryClients += 1
        if discoveryClients == 1 { startBrowsing() }
    }

    func endDiscovery() {
        discoveryClients = max(0, discoveryClients - 1)
        guard discoveryClients == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.discoveryClients == 0 else { return }
            self.browser.stop()
            self.discoveryStatus = .idle
        }
    }

    private func startBrowsing() {
        guard networkAvailable else {
            discoveryStatus = .noNetwork
            return
        }
        if !browser.isRunning {
            discoveryStatus = .browsing
            browser.start()
        }
    }

    private func updateNearby(_ devices: [DiscoveredDevice]) {
        let before = Set(discovered.map { $0.deviceId })
        discovered = devices
        refreshNearby()
        // A paired device with queued sends just showed up in discovery: deliver.
        let appeared = Set(devices.map { $0.deviceId }).subtracting(before)
        for deviceId in Set(sendQueue.map { $0.deviceId }) where appeared.contains(deviceId) {
            deliverQueue(for: deviceId, force: true)
        }
    }

    /// Discovered devices (private ones only when paired or in a shared Drip Room), plus
    /// paired devices that discovery can't see but that answered at a known address before.
    private func refreshNearby() {
        let trusted = Dictionary(trustedDevices.map { ($0.deviceId, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = discovered.filter { !$0.isPrivate || trusted[$0.deviceId] != nil || room(forHints: $0.roomHints) != nil }
        var devices = visible.map { device -> DiscoveredDevice in
            guard let record = trusted[device.deviceId] else { return device }
            // Show the name the user knows (a private device advertises a random one).
            return DiscoveredDevice(deviceId: device.deviceId, name: record.name, platform: device.platform,
                                    endpoint: device.endpoint, isPrivate: device.isPrivate,
                                    roomHints: device.roomHints)
        }
        let seen = Set(devices.map(\.deviceId))
        for record in trustedDevices where !seen.contains(record.deviceId) {
            guard let host = record.lastHost, let port = record.lastPort, let nwPort = NWEndpoint.Port(rawValue: port) else { continue }
            devices.append(DiscoveredDevice(deviceId: record.deviceId, name: record.name, platform: record.platform,
                                            endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
                                            isRemembered: true))
        }
        nearby = devices
        multiSelection = multiSelection.filter { id in devices.contains { $0.deviceId == id } }
        if let selected = selectedDeviceId, !devices.contains(where: { $0.deviceId == selected }) {
            selectedDeviceId = nil
        }
        if selectedDeviceId == nil, devices.count == 1 {
            selectedDeviceId = devices[0].deviceId
        }
        discoveredCount = discovered.count
        updateClipboardWatcher()
    }

    /// Devices found by discovery right now (not counting remembered ones).
    @Published private(set) var discoveredCount = 0

    func isTrusted(_ deviceId: String) -> Bool {
        trustedDevices.contains { $0.deviceId == deviceId }
    }

    func trustedRecord(for deviceId: String) -> TrustedDeviceRecord? {
        trustedDevices.first { $0.deviceId == deviceId }
    }

    /// A paired phone marked "This is my device" (permanent pairing, auto-accept).
    func isMyPhone(_ deviceId: String) -> Bool {
        guard let record = trustedRecord(for: deviceId) else { return false }
        return record.platform == "android" && record.autoAccept && !record.isTemporary
    }

    var selectedDevice: DiscoveredDevice? {
        nearby.first { $0.deviceId == selectedDeviceId }
    }

    // MARK: - Network and power

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let signature = path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
            DispatchQueue.main.async { self?.networkChanged(usable: usable, signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "app.crossdrop.path"))
        pathMonitor = monitor
    }

    private func networkChanged(usable: Bool, signature: String) {
        let first = networkSignature == nil
        let changed = usable != networkAvailable || (!first && signature != networkSignature)
        networkAvailable = usable
        networkSignature = signature
        guard changed else { return }
        restartNetworking()
        // New network: one direct try for queued sends, once it has settled.
        if usable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.deliverQueue() }
        }
    }

    func handleWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.restartNetworking()
            self?.checkExpiringFiles()
            self?.purgeExpiredTrust()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.deliverQueue() }
    }

    private func restartNetworking() {
        if receivingEnabled {
            startServer()
        }
        if discoveryClients > 0 {
            browser.stop()
            startBrowsing()
        } else if !networkAvailable {
            discoveryStatus = .noNetwork
        }
    }

    // MARK: - Files

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or folders to send. Folders arrive with their structure."
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls)
        }
    }

    func addDroppedItems(_ providers: [NSItemProvider]) {
        Self.loadFileURLs(from: providers) { [weak self] urls in self?.addFiles(urls) }
    }

    /// Reads the file URLs out of dropped items; `completion` runs once, on the main thread.
    static func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let type = UTType.fileURL.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !matching.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [(Int, URL)] = []
        for (index, provider) in matching.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                if let fileURL = url, fileURL.isFileURL {
                    lock.lock()
                    found.append((index, fileURL))
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(found.sorted { $0.0 < $1.0 }.map { $0.1 })
        }
    }

    func addFiles(_ urls: [URL]) {
        let (added, skipped) = Self.gather(urls, into: &selectedFiles)
        if selectedFiles.count > ProtocolConstants.maxFilesPerOffer {
            selectedFiles = Array(selectedFiles.prefix(ProtocolConstants.maxFilesPerOffer))
            show("Up to \(ProtocolConstants.maxFilesPerOffer) files can go in one send; the rest were left out.")
        } else if skipped > 0 {
            show(skipped == 1 ? "1 item was skipped (a link or an unreadable file)."
                              : "\(skipped) items were skipped (links or unreadable files).")
        }
        if added > 0 { pendingText = nil }
    }

    /// Adds files and folders (expanded, keeping their structure) to `list`, skipping links
    /// and duplicates. Shared by the Send tray, the Shelf and Drip Island.
    static func gather(_ urls: [URL], into list: inout [SelectedFile]) -> (added: Int, skipped: Int) {
        var added = 0
        var skipped = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { skipped += 1; continue }
            if values?.isDirectory == true {
                let (count, rest) = addFolder(url, into: &list)
                added += count
                skipped += rest
                continue
            }
            if add(url, path: [], into: &list) { added += 1 }
        }
        return (added, skipped)
    }

    /// Adds every regular file under `folder`, keeping its structure (§9.1).
    /// Hidden files and symbolic links are skipped.
    private static func addFolder(_ folder: URL, into selectedFiles: inout [SelectedFile]) -> (added: Int, skipped: Int) {
        let base = folder.standardizedFileURL.pathComponents
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return (0, 1)
        }
        var added = 0
        var skipped = 0
        for case let url as URL in walker {
            guard selectedFiles.count < ProtocolConstants.maxFilesPerOffer + 1 else { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { skipped += 1; continue }
            guard values?.isRegularFile == true else { continue }
            let parts = url.standardizedFileURL.deletingLastPathComponent().pathComponents
            let inside = Array(parts.dropFirst(base.count))
            let path = [folder.lastPathComponent] + inside
            if path.count > ProtocolConstants.maxPathComponents { skipped += 1; continue }
            if add(url, path: path, into: &selectedFiles) { added += 1 }
        }
        return (added, skipped)
    }

    private static func add(_ url: URL, path: [String], into selectedFiles: inout [SelectedFile]) -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile ?? true else { return false }
        if selectedFiles.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { return false }
        selectedFiles.append(SelectedFile(url: url, name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0), path: path))
        return true
    }

    /// Takes a link or text from the clipboard to send. Only when the user asks.
    @discardableResult
    func takeClipboard() -> Bool {
        guard let raw = NSPasteboard.general.string(forType: .string), let text = PendingText.from(raw) else {
            show("The clipboard has no link or text to send.")
            return false
        }
        pendingText = text
        selectedFiles.removeAll()
        return true
    }

    func removeFile(_ file: SelectedFile) {
        selectedFiles.removeAll { $0.id == file.id }
    }

    func clearSelection() {
        selectedFiles.removeAll()
        pendingText = nil
    }

    var hasSomethingToSend: Bool { !selectedFiles.isEmpty || pendingText != nil }

    var selectedTotalBytes: Int64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    // MARK: - Sending

    func sendSelection(to device: DiscoveredDevice) {
        sendSelection(to: [device])
    }

    /// Sends what is selected (files, or a link / text) to each device; every device
    /// gets its own transfer, verified separately.
    func sendSelection(to devices: [DiscoveredDevice]) {
        guard !devices.isEmpty else { return }
        let options = SendOptions(expiresAfter: autoDeleteNextSend ? Self.autoDeleteSeconds : nil)
        if let text = pendingText {
            let name = text.kind == .link ? "Link" : "Text"
            for device in devices {
                startTransfer(files: [OutgoingFile.text(text.text, name: name)], to: device, kind: text.kind,
                              text: text.kind == .link ? text.text : nil)
            }
            pendingText = nil
        } else {
            guard !selectedFiles.isEmpty else { return }
            let files = Self.outgoingFiles(selectedFiles)
            for device in devices { startTransfer(files: files, to: device, options: options) }
            selectedFiles.removeAll()
            autoDeleteNextSend = false
        }
        multiSelecting = false
        multiSelection.removeAll()
    }

    /// "Auto-delete on arrival after 24 h" (§9.8).
    static let autoDeleteSeconds: Int64 = 86_400

    static func outgoingFiles(_ selection: [SelectedFile]) -> [OutgoingFile] {
        selection.map { file in
            OutgoingFile(url: file.url, name: file.name,
                         mime: UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType,
                         path: file.path)
        }
    }

    /// Sends files straight to a device without touching the Send tray (Drip Island, Shelf).
    func send(urls: [URL], to device: DiscoveredDevice, expiresAfter: Int64? = nil) {
        var gathered: [SelectedFile] = []
        let (_, skipped) = Self.gather(urls, into: &gathered)
        guard !gathered.isEmpty else {
            show("Nothing to send there: links and unreadable items are skipped.")
            return
        }
        if gathered.count > ProtocolConstants.maxFilesPerOffer {
            gathered = Array(gathered.prefix(ProtocolConstants.maxFilesPerOffer))
            show("Up to \(ProtocolConstants.maxFilesPerOffer) files can go in one send; the rest were left out.")
        } else if skipped > 0 {
            show(skipped == 1 ? "1 item was skipped (a link or an unreadable file)."
                              : "\(skipped) items were skipped (links or unreadable files).")
        }
        startTransfer(files: Self.outgoingFiles(gathered), to: device, options: SendOptions(expiresAfter: expiresAfter))
    }

    func send(providers: [NSItemProvider], to device: DiscoveredDevice) {
        Self.loadFileURLs(from: providers) { [weak self] urls in
            guard !urls.isEmpty else { return }
            self?.send(urls: urls, to: device)
        }
    }

    /// Sends the clipboard to one device straight away (device context menus). Leaves the
    /// Send tray (files or a link waiting there) untouched.
    func sendClipboard(to device: DiscoveredDevice) {
        guard let raw = NSPasteboard.general.string(forType: .string), let text = PendingText.from(raw) else {
            show("The clipboard has no link or text to send.")
            return
        }
        startTransfer(files: [OutgoingFile.text(text.text, name: text.kind == .link ? "Link" : "Text")], to: device,
                      kind: text.kind, text: text.kind == .link ? text.text : nil)
    }

    private func startTransfer(files: [OutgoingFile], to device: DiscoveredDevice, kind: OfferKind = .files,
                               text: String? = nil, options: SendOptions = SendOptions()) {
        // An unpaired device that shares our Drip Room pairs by proving the room (§9.9).
        let room = isTrusted(device.deviceId) ? nil : self.room(forHints: device.roomHints)
        // Turbo (§9.10, experimental): parallel connections for multi-file sends, if the receiver agrees.
        let turbo = turboEnabled && kind == .files && files.count >= 2 ? ProtocolConstants.maxTurboStreams : 1
        let expiresAfter = kind == .files ? options.expiresAfter : nil
        let transfer = OutgoingTransfer(endpoint: device.endpoint, peerName: device.name, peerId: device.deviceId,
                                        peerPlatform: device.platform, files: files, identity: identity,
                                        local: localInfo, trust: trustStore, delegate: self, kind: kind,
                                        expiresAfter: expiresAfter, room: room, turbo: turbo)
        outgoing[transfer.id] = transfer
        if options.quiet {
            quietIds.insert(transfer.id)
        } else {
            retryInfo[transfer.id] = RetryInfo(files: files, deviceId: device.deviceId, deviceName: device.name,
                                               platform: device.platform, kind: kind, text: text,
                                               expiresAfter: expiresAfter)
        }
        if let queueId = options.queueId {
            queueAttempts[transfer.id] = queueId
            deliveringQueueIds.insert(queueId)
        }
        if options.quiet || options.queueId != nil { expectedPeers[transfer.id] = device.deviceId }
        if let text = text { sentText[transfer.id] = text }
        upsert(transfer.snapshot)
        let trust = trustStore
        Task.detached { [weak self] in
            let result = await transfer.run()
            // Remember where a paired device answered, for networks that block discovery.
            if result.phase == .completed, let peerId = result.peerId, let address = transfer.connectedAddress {
                trust.rememberAddress(address.host, port: address.port, for: peerId)
            }
            DispatchQueue.main.async { self?.outgoing[transfer.id] = nil }
        }
    }

    func canRetry(_ item: TransferItem) -> Bool {
        item.snapshot.direction == .outgoing
            && (item.snapshot.phase == .failed || item.snapshot.phase == .cancelled)
            && retryInfo[item.id] != nil
            && !isStillQueued(item.id)
    }

    /// A shown queue attempt that failed but whose send is still waiting in the queue.
    private func isStillQueued(_ transferId: String) -> Bool {
        guard let queueId = keptQueueAttempts[transferId] else { return false }
        return sendQueue.contains { $0.id == queueId }
    }

    func retry(_ item: TransferItem) {
        guard let info = retryInfo[item.id] else { return }
        guard let device = nearby.first(where: { $0.deviceId == info.deviceId }) else {
            show("\(item.snapshot.peerName) isn't nearby right now. Open CrossDrop on it and turn on Receiving.")
            return
        }
        transfers.removeAll { $0.id == item.id }
        startTransfer(files: info.files, to: device, kind: info.kind, text: sentText[item.id],
                      options: SendOptions(expiresAfter: info.expiresAfter))
    }

    /// History "Send again": puts the files (if they still exist) or the link back in
    /// the tray on the Send page, so the user picks where they go.
    func sendAgain(_ entry: HistoryEntry) {
        if entry.kind == "link", let link = entry.link, let text = PendingText.from(link) {
            selectedFiles.removeAll()
            pendingText = text
        } else {
            let urls = entry.files.compactMap { $0.path }.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            guard !urls.isEmpty else {
                show("Those files are no longer where they were.")
                return
            }
            pendingText = nil
            addFiles(urls)
        }
        selectedTab = .send
    }

    func cancel(_ item: TransferItem) {
        if let transfer = outgoing[item.id] {
            transfer.cancel()
        } else {
            server?.cancelTransfer(id: item.id)
        }
    }

    func dismiss(_ item: TransferItem) {
        guard item.snapshot.phase.isFinished else { return }
        transfers.removeAll { $0.id == item.id }
        retryInfo[item.id] = nil
        keptQueueAttempts[item.id] = nil
    }

    var activeTransfers: [TransferItem] {
        transfers.filter { !$0.snapshot.phase.isFinished }
    }

    // MARK: - Prompts

    var activePromptBinding: PromptItem? {
        get { prompts.first }
        set {
            // The sheet was dismissed by the system (e.g. Esc): treat as "no".
            // Only for the prompt that is actually on screen, never the next one.
            if newValue == nil, let current = prompts.first, current.id == presentedPromptId {
                respond(to: current, accept: false)
            }
        }
    }

    /// Set by the prompt sheet when it appears.
    var presentedPromptId: String?

    func respond(to prompt: PromptItem, accept: Bool, mine: Bool = false) {
        switch prompt {
        case .pairing(let pairing, let decision):
            decision.resolve(accept, mine: mine)
            if accept {
                waitingPairingIds.insert(pairing.id)
            } else {
                prompts.removeAll { $0.id == prompt.id }
            }
        case .offer(_, let decision):
            decision.resolve(accept)
            prompts.removeAll { $0.id == prompt.id }
        }
    }

    func requestMainWindow() {
        windowRequest += 1
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Devices and history

    func forget(_ device: TrustedDeviceRecord) {
        trustStore.forget(device.deviceId)
    }

    func setAutoAccept(_ value: Bool, for device: TrustedDeviceRecord) {
        trustStore.setAutoAccept(value, for: device.deviceId)
    }

    /// Clears the list, except received files still waiting to go to the Trash: their row
    /// holds the only Keep button, so it stays until they are deleted or kept.
    func clearHistory() {
        historyStore.clear()
        history = historyStore.entries
    }

    /// History rows that stay when the list is cleared (expiring drops still pending).
    var pendingExpiringCount: Int {
        history.filter { $0.isPendingExpiry }.count
    }

    func reveal(_ urls: [URL]) {
        // Files sorted by type after arrival are shown where they are now.
        let current = urls.map { relocated[$0.path] ?? $0 }
        let existing = current.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            show("Those files are no longer where they were saved.")
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    // MARK: - Settings

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != deviceName else { return }
        deviceName = String(trimmed.prefix(64))
        AppSettings.deviceName = deviceName
        if receivingEnabled { startServer() }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination
        panel.prompt = "Use Folder"
        panel.message = "Received files are saved here."
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            AppSettings.destination = url
            self?.destination = url
        }
    }

    func setAutoOff(minutes: Int) {
        autoOffMinutes = minutes
        AppSettings.autoOffMinutes = minutes
        scheduleAutoOff()
    }

    func setNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        AppSettings.notificationsEnabled = enabled
        if enabled { NotificationManager.shared.requestAuthorization { _ in } }
    }

    func setHeicToJpeg(_ enabled: Bool) {
        heicToJpeg = enabled
        AppSettings.heicToJpeg = enabled
    }

    // MARK: - Pairing QR code (§9.4)

    /// The URI a phone scans to pair without comparing numbers. Holds a one-time token
    /// (valid 5 minutes), this Mac's key fingerprint and its addresses; no secrets beyond
    /// the single-use token, which only lets the scanner skip the code comparison.
    func pairingURI(mine: Bool) -> String? {
        guard let server = server, let port = listeningPort else { return nil }
        let hosts = Self.localIPv4Addresses()
        guard !hosts.isEmpty else { return nil }
        let token = server.pairingTokens.issue(mine: mine)
        var components = URLComponents()
        components.scheme = "crossdrop"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: "\(ProtocolConstants.version)"),
            URLQueryItem(name: "id", value: identity.deviceId),
            URLQueryItem(name: "fp", value: identity.fingerprint),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "n", value: String(deviceName.prefix(40))),
            URLQueryItem(name: "p", value: "\(port)"),
            URLQueryItem(name: "h", value: hosts.prefix(4).joined(separator: ",")),
        ]
        return components.string
    }

    /// Unused codes stop working when the sheet closes.
    func endPairingCodes() {
        server?.pairingTokens.revokeAll()
    }

    /// This Mac's IPv4 addresses on Wi-Fi / Ethernet interfaces (en*), private ranges first.
    static func localIPv4Addresses() -> [String] {
        var result: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = item.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0,
                  let addr = item.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if !text.hasPrefix("169.254.") { result.append(text) }
            }
        }
        return result
    }

    func setSoundOnDone(_ enabled: Bool) {
        soundOnDone = enabled
        AppSettings.soundOnDone = enabled
        if enabled { DoneSound.play() }
    }

    var outgoingTransfers: [TransferItem] {
        transfers.filter { $0.snapshot.direction == .outgoing }
    }

    var incomingTransfers: [TransferItem] {
        transfers.filter { $0.snapshot.direction == .incoming }
    }

    // MARK: - Shelf ("Pocket")

    static let shelfLimit = 200

    /// Stashes files and folders on the Shelf. Only their paths are kept, across launches.
    func stash(_ urls: [URL]) {
        var added = 0
        for url in urls where url.isFileURL {
            let path = url.standardizedFileURL.path
            guard !shelf.contains(where: { $0.path == path }), FileManager.default.fileExists(atPath: path) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            let isFolder = values?.isDirectory == true
            shelf.insert(ShelfItem(id: UUID(), path: path, name: url.lastPathComponent,
                                   size: isFolder ? 0 : Int64(values?.fileSize ?? 0),
                                   isFolder: isFolder, addedAt: Date()), at: 0)
            added += 1
        }
        guard added > 0 else { return }
        if shelf.count > Self.shelfLimit { shelf = Array(shelf.prefix(Self.shelfLimit)) }
        shelfFile.save(shelf)
        refreshShelfPresence()
    }

    func stash(providers: [NSItemProvider]) {
        Self.loadFileURLs(from: providers) { [weak self] urls in self?.stash(urls) }
    }

    func removeFromShelf(_ item: ShelfItem) {
        shelf.removeAll { $0.id == item.id }
        shelfFile.save(shelf)
        missingShelfIds.remove(item.id)
    }

    /// Drops items whose file was moved or deleted outside CrossDrop.
    func removeMissingFromShelf() {
        shelf.removeAll { !$0.exists }
        shelfFile.save(shelf)
        missingShelfIds = []
    }

    func clearShelf() {
        shelf.removeAll()
        shelfFile.save(shelf)
        missingShelfIds = []
    }

    /// False when the item's file was moved or deleted (as of the last check).
    func isPresent(_ item: ShelfItem) -> Bool {
        !missingShelfIds.contains(item.id)
    }

    /// Re-checks which Shelf files still exist: when the Shelf changes, CrossDrop comes to
    /// the front or a panel showing the Shelf opens. One stat per item, never per redraw.
    func refreshShelfPresence() {
        let missing = Self.missingIds(in: shelf)
        if missing != missingShelfIds { missingShelfIds = missing }
    }

    private static func missingIds(in items: [ShelfItem]) -> Set<UUID> {
        Set(items.filter { !$0.exists }.map { $0.id })
    }

    /// Sends Shelf items (all of them when `items` is nil) straight to a device. They stay on the Shelf.
    func sendShelf(_ items: [ShelfItem]? = nil, to device: DiscoveredDevice) {
        let urls = (items ?? shelf).filter { $0.exists }.map { $0.url }
        refreshShelfPresence()
        guard !urls.isEmpty else {
            show("Those files are no longer where they were.")
            return
        }
        send(urls: urls, to: device)
    }

    /// Puts Shelf items in the Send tray, to pick devices or several at once.
    func addShelfToSelection(_ items: [ShelfItem]? = nil) {
        let urls = (items ?? shelf).filter { $0.exists }.map { $0.url }
        refreshShelfPresence()
        guard !urls.isEmpty else {
            show("Those files are no longer where they were.")
            return
        }
        pendingText = nil
        addFiles(urls)
        selectedTab = .send
    }

    func revealShelfItems(_ items: [ShelfItem]) {
        reveal(items.map { $0.url })
    }

    // MARK: - Send when nearby

    /// Gap between automatic tries of one queued send, so a flapping network can't cause a loop.
    static let queueRetryGap: TimeInterval = 60

    /// True for a failed send to a paired device that can wait in the queue.
    func canSendWhenNearby(_ item: TransferItem) -> Bool {
        guard item.snapshot.direction == .outgoing, item.snapshot.phase == .failed,
              !fromQueue.contains(item.id), let info = retryInfo[item.id] else { return false }
        return isPermanentlyPaired(info.deviceId)
    }

    /// Paired for good (not a Drip Room member whose trust ends with the room).
    func isPermanentlyPaired(_ deviceId: String) -> Bool {
        trustedRecord(for: deviceId).map { !$0.isTemporary } ?? false
    }

    /// Keeps a failed send and delivers it automatically when the device is back.
    func sendWhenNearby(_ item: TransferItem) {
        guard !fromQueue.contains(item.id) else { return }
        guard let info = retryInfo[item.id], isPermanentlyPaired(info.deviceId) else {
            show("Only sends to devices paired for good can wait until they are nearby.")
            return
        }
        var files: [QueuedSend.File] = []
        var text: String? = nil
        switch info.kind {
        case .files:
            files = info.files.filter { $0.data == nil }.map { QueuedSend.File(path: $0.url.path, name: $0.name, folders: $0.path) }
        case .link, .text:
            text = info.text ?? info.files.first?.data.flatMap { String(data: $0, encoding: .utf8) }
        }
        guard !files.isEmpty || text != nil else { return }
        enqueue(QueuedSend(id: UUID(), deviceId: info.deviceId, deviceName: info.deviceName, platform: info.platform,
                           kind: info.kind.rawValue, files: files, text: text, expiresAfter: info.expiresAfter,
                           createdAt: Date()))
        transfers.removeAll { $0.id == item.id }
        retryInfo[item.id] = nil
    }

    /// Queues what is in the Send tray for a paired device that isn't around right now.
    func queueSelection(for device: TrustedDeviceRecord) {
        guard !device.isTemporary else {
            show("Room members can't be queued: their trust ends with the room.")
            return
        }
        let expiresAfter = autoDeleteNextSend ? Self.autoDeleteSeconds : nil
        if let pending = pendingText {
            enqueue(QueuedSend(id: UUID(), deviceId: device.deviceId, deviceName: device.name, platform: device.platform,
                               kind: pending.kind.rawValue, files: [], text: pending.text, expiresAfter: nil,
                               createdAt: Date()))
            pendingText = nil
        } else if !selectedFiles.isEmpty {
            let files = selectedFiles.map { QueuedSend.File(path: $0.url.path, name: $0.name, folders: $0.path) }
            enqueue(QueuedSend(id: UUID(), deviceId: device.deviceId, deviceName: device.name, platform: device.platform,
                               kind: OfferKind.files.rawValue, files: files, text: nil, expiresAfter: expiresAfter,
                               createdAt: Date()))
            selectedFiles.removeAll()
            autoDeleteNextSend = false
        }
    }

    func cancelQueued(_ item: QueuedSend) {
        sendQueue.removeAll { $0.id == item.id }
        queueFile.save(sendQueue)
    }

    func queuedSends(for deviceId: String) -> [QueuedSend] {
        sendQueue.filter { $0.deviceId == deviceId }
    }

    /// "Try Now" for queued sends: one attempt each, ignoring the retry gap.
    func retryQueueNow() {
        deliverQueue(force: true)
        if !sendQueue.contains(where: { item in nearby.contains { $0.deviceId == item.deviceId } }) {
            show("None of those devices is nearby yet. CrossDrop sends as soon as one shows up.")
        }
    }

    private func enqueue(_ item: QueuedSend) {
        sendQueue.append(item)
        queueFile.save(sendQueue)
        show("\(item.summary) will go to \(item.deviceName) as soon as it's nearby.")
        // Found by discovery right now: try at once. Otherwise wait for it to show up.
        if discovered.contains(where: { $0.deviceId == item.deviceId }) {
            deliverQueue(for: item.deviceId, force: true)
        }
    }

    /// Tries queued sends whose device is reachable: found by discovery, or a paired device
    /// at the address that worked last (one direct try). Event-driven only (discovery results,
    /// launch, wake, network change, the device reaching us); it never polls.
    func deliverQueue(for deviceId: String? = nil, force: Bool = false) {
        guard networkAvailable, !sendQueue.isEmpty else { return }
        let busy = Set(sendQueue.filter { deliveringQueueIds.contains($0.id) }.map { $0.deviceId })
        var startedFor: Set<String> = []
        var changed = false
        for item in sendQueue {
            if let only = deviceId, item.deviceId != only { continue }
            // One at a time per device, oldest first.
            if busy.contains(item.deviceId) || startedFor.contains(item.deviceId) { continue }
            if !force, let last = item.lastAttemptAt, Date().timeIntervalSince(last) < Self.queueRetryGap { continue }
            guard let record = trustedRecord(for: item.deviceId), !record.isTemporary else {
                dropQueued(item, reason: "\(item.deviceName) is no longer paired, so a send waiting for it was removed.")
                changed = true
                continue
            }
            guard let device = nearby.first(where: { $0.deviceId == item.deviceId }) else { continue }
            let files: [OutgoingFile]
            switch item.offerKind {
            case .files:
                let present = item.files.filter { FileManager.default.isReadableFile(atPath: $0.path) }
                guard !present.isEmpty else {
                    dropQueued(item, reason: "A send waiting for \(item.deviceName) was removed: its files are no longer there.")
                    changed = true
                    continue
                }
                files = present.map { file in
                    OutgoingFile(url: URL(fileURLWithPath: file.path), name: file.name,
                                 mime: UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType,
                                 path: file.folders)
                }
            case .link, .text:
                guard let text = item.text else {
                    dropQueued(item, reason: nil)
                    changed = true
                    continue
                }
                files = [OutgoingFile.text(text, name: item.offerKind == .link ? "Link" : "Text")]
            }
            if let index = sendQueue.firstIndex(where: { $0.id == item.id }) {
                sendQueue[index].attempts += 1
                sendQueue[index].lastAttemptAt = Date()
                sendQueue[index].deviceName = device.name
                changed = true
            }
            startedFor.insert(item.deviceId)
            startTransfer(files: files, to: device, kind: item.offerKind,
                          text: item.offerKind == .link ? item.text : nil,
                          options: SendOptions(expiresAfter: item.expiresAfter, queueId: item.id))
        }
        if changed { queueFile.save(sendQueue) }
    }

    private func dropQueued(_ item: QueuedSend, reason: String?) {
        sendQueue.removeAll { $0.id == item.id }
        queueFile.save(sendQueue)
        if let reason = reason { show(reason) }
    }

    /// Transfers that came from the queue (so a failure doesn't offer to queue them again).
    private var fromQueue: Set<String> = []
    /// Queue attempts cancelled because a different device answered at the old address.
    private var suppressedQueueAttempts: Set<String> = []

    /// A queued send is silent until it really reaches the device: a try that can't connect
    /// leaves no card, no history and no notification, and the send stays queued.
    /// Returns false when the normal card / history handling should be skipped.
    private func handleQueueUpdate(_ snapshot: TransferSnapshot, queueId: UUID) -> Bool {
        let id = snapshot.id
        fromQueue.insert(id)
        // The device was paired when queued; a pairing request, or a different device answering
        // the handshake, means someone else now has its old address.
        if !snapshot.phase.isFinished, !shownQueueAttempts.contains(id),
           snapshot.phase == .pairing || wrongPeer(snapshot) {
            suppressedQueueAttempts.insert(id)
            outgoing[id]?.cancel()
            return false
        }
        if !shownQueueAttempts.contains(id) {
            if snapshot.phase.isFinished {
                if suppressedQueueAttempts.remove(id) != nil || Self.isUnreachable(snapshot) {
                    finishQueueAttempt(id, queueId: queueId, delivered: false, keep: true)
                    return false
                }
            } else if snapshot.phase == .preparing || snapshot.phase == .connecting {
                return false
            }
            shownQueueAttempts.insert(id)
        }
        if snapshot.phase.isFinished {
            // Dropped part-way: keep it queued (the receiver may resume, §9.3).
            let keep = snapshot.phase == .failed && Self.isUnreachable(snapshot)
            finishQueueAttempt(id, queueId: queueId, delivered: snapshot.phase == .completed, keep: keep)
        }
        return true
    }

    private static func isUnreachable(_ snapshot: TransferSnapshot) -> Bool {
        guard snapshot.phase == .failed, let code = snapshot.error?.code else { return false }
        return code == ErrorCode.unreachable || code == ErrorCode.connectionLost || code == ErrorCode.timeout
    }

    private func finishQueueAttempt(_ transferId: String, queueId: UUID, delivered: Bool, keep: Bool) {
        queueAttempts[transferId] = nil
        expectedPeers[transferId] = nil
        if !shownQueueAttempts.contains(transferId) {
            // A silent try: nothing on screen can retry it.
            retryInfo[transferId] = nil
            sentText[transferId] = nil
        } else if keep {
            // Its card stays, but the send is still queued: no Retry / Send When Nearby there.
            keptQueueAttempts[transferId] = queueId
        }
        shownQueueAttempts.remove(transferId)
        deliveringQueueIds.remove(queueId)
        let deviceId = sendQueue.first { $0.id == queueId }?.deviceId
        if !keep {
            sendQueue.removeAll { $0.id == queueId }
            queueFile.save(sendQueue)
        }
        if delivered, let deviceId = deviceId {
            // Next one for the same device.
            DispatchQueue.main.async { [weak self] in self?.deliverQueue(for: deviceId, force: true) }
        }
    }

    /// True when the device that answered the handshake is not the one a silent send was
    /// started for. The core doesn't check this before pairing or offering (see the report on
    /// `expectedPeerId`), so the app stops such a send as soon as it sees the snapshot.
    private func wrongPeer(_ snapshot: TransferSnapshot) -> Bool {
        guard let expected = expectedPeers[snapshot.id], let answered = snapshot.peerId else { return false }
        return answered != expected
    }

    /// A send to a paired device failed because it couldn't be reached: offer to keep it.
    private func offerQueueIfUnreachable(_ snapshot: TransferSnapshot) {
        guard snapshot.direction == .outgoing, snapshot.phase == .failed,
              snapshot.error?.code == ErrorCode.unreachable, !fromQueue.contains(snapshot.id),
              let info = retryInfo[snapshot.id], isTrusted(info.deviceId),
              trustedRecord(for: info.deviceId)?.isTemporary == false else { return }
        show("Couldn't reach \(info.deviceName). CrossDrop can send it when \(info.deviceName) is back.",
             action: .sendWhenNearby(snapshot.id))
    }

    // MARK: - Take Photo / Pick Photo with the phone (§9.7)

    /// Phones paired for good that this Mac can ask for a photo: found nearby or at their last
    /// address. Drip Room members are left out: a meeting stranger's phone is never "your phone".
    var capturePhones: [DiscoveredDevice] {
        let phones = nearby.filter { $0.platform == "android" && isPermanentlyPaired($0.deviceId) }
        return phones.filter { !$0.isRemembered } + phones.filter { $0.isRemembered }
    }

    /// The phone the menu bar's "Take Photo" uses: one marked "mine" if there is one.
    var capturePhone: DiscoveredDevice? {
        capturePhones.first { isMyPhone($0.deviceId) } ?? capturePhones.first
    }

    /// Asks a paired phone to take (or pick) a photo and send it back; it lands on the clipboard.
    /// Receiving must be on so the phone can answer; when it is Off the request waits for the
    /// user to allow "My Devices" (see `CaptureState.Phase.needsReceiving`).
    func requestCapture(_ kind: CaptureKind, from device: DiscoveredDevice? = nil) {
        guard let device = device ?? capturePhone else {
            show("Pair your phone first and keep CrossDrop open on it. The photo comes straight to this Mac's clipboard.")
            return
        }
        guard device.platform == "android", isPermanentlyPaired(device.deviceId) else {
            show(isTrusted(device.deviceId)
                 ? "\(device.name) is in your Drip Room only. Pair it with this Mac to ask it for photos."
                 : "\(device.name) needs to be paired with this Mac first.")
            return
        }
        if let current = capture, current.isActive {
            show("Still waiting for \(current.deviceName).")
            return
        }
        captureTimer?.invalidate()
        guard receivingEnabled else {
            capture = CaptureState(kind: kind, deviceId: device.deviceId, deviceName: device.name, requestId: nil,
                                   phase: .needsReceiving, startedAt: Date())
            show("Receiving is Off, so \(device.name) can't send the photo back. My Devices lets only your paired devices send.",
                 action: .useMyDevices)
            return
        }
        guard server != nil, listeningPort != nil else {
            // The receiver is starting; ask as soon as it is ready.
            capture = CaptureState(kind: kind, deviceId: device.deviceId, deviceName: device.name, requestId: nil,
                                   phase: .asking, startedAt: Date())
            captureAfterReady = (kind, device.deviceId)
            waitForReceiverThenCapture()
            return
        }
        launchCapture(kind, device: device)
    }

    /// "Try Again" on a failed photo request: asks the same phone again, never another one.
    func retryCapture() {
        guard let failed = capture, !failed.isActive else { return }
        guard let device = nearby.first(where: { $0.deviceId == failed.deviceId }) else {
            let message = "\(failed.deviceName) isn't nearby right now. Open CrossDrop on it, then try again."
            capture?.phase = .failed(message)
            show(message)
            return
        }
        requestCapture(failed.kind, from: device)
    }

    /// Lets the phone answer: switches receiving to My Devices, then asks.
    func allowCaptureReplies() {
        guard let pending = capture, pending.phase == .needsReceiving else { return }
        captureAfterReady = (pending.kind, pending.deviceId)
        capture?.phase = .asking
        setReceiveMode(.mine)
        // Already listening (receiving was not really off): ask straight away.
        if server != nil, listeningPort != nil, let waiting = captureAfterReady {
            captureAfterReady = nil
            launchPendingCapture(waiting.kind, deviceId: waiting.deviceId)
        } else {
            waitForReceiverThenCapture()
        }
    }

    /// How long a photo request waits for receiving to become ready before giving up.
    static let captureReadyTimeout: TimeInterval = 20

    /// The request waits for `apply(.ready)`. Fails at once when the receiver can't become
    /// ready by itself (no network, Local Network denied, failed), and after a short timeout
    /// otherwise, so the card never stays at "Asking…" with its rings moving.
    private func waitForReceiverThenCapture() {
        switch receiverStatus {
        case .noNetwork:
            captureFailed("This Mac isn't on Wi-Fi or Ethernet, so the phone has nowhere to send the photo.")
            return
        case .localNetworkDenied:
            captureFailed("Allow Local Network access for CrossDrop in System Settings, then ask again.")
            return
        case .failed:
            captureFailed("Receiving couldn't start, so the phone has nowhere to send the photo.")
            return
        case .off, .starting, .ready:
            break
        }
        captureTimer?.invalidate()
        guard let state = capture else { return }
        let timer = Timer(timeInterval: Self.captureReadyTimeout, repeats: false) { [weak self] _ in
            guard let self = self, self.captureAfterReady != nil, self.capture?.id == state.id,
                  self.capture?.phase == .asking else { return }
            self.captureFailed("Receiving isn't ready, so \(state.deviceName) has nowhere to send the photo. Try again in a moment.")
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
    }

    /// Sends a request that was waiting for the receiver, if the phone is still around.
    private func launchPendingCapture(_ kind: CaptureKind, deviceId: String) {
        captureTimer?.invalidate()
        captureTimer = nil
        if let device = nearby.first(where: { $0.deviceId == deviceId }) {
            launchCapture(kind, device: device)
        } else if let name = capture?.deviceName {
            captureFailed("\(name) isn't nearby any more. Open CrossDrop on it, then try again.")
        } else {
            capture = nil
        }
    }

    private func launchCapture(_ kind: CaptureKind, device: DiscoveredDevice) {
        guard let server = server, let port = listeningPort else {
            captureFailed("Receiving isn't ready yet. Try again in a moment.")
            return
        }
        let state = CaptureState(kind: kind, deviceId: device.deviceId, deviceName: device.name, requestId: nil,
                                 phase: .asking, startedAt: Date())
        capture = state
        let registry = server.captureRequests
        let identity = self.identity
        let local = localInfo
        let trust: TrustProvider = trustStore
        let endpoint = device.endpoint
        let deviceId = device.deviceId
        let name = device.name
        Task.detached { [weak self] in
            do {
                let requestId = try await CaptureClient.request(endpoint: endpoint, expectedDeviceId: deviceId,
                                                                identity: identity, local: local, trust: trust,
                                                                kind: kind, replyPort: port, registry: registry)
                DispatchQueue.main.async {
                    guard let self = self, self.capture?.id == state.id else {
                        registry.cancel(requestId)
                        return
                    }
                    self.capture?.requestId = requestId
                    self.capture?.phase = .waiting
                    self.armCaptureTimeout()
                }
            } catch {
                let message = AppModel.captureErrorMessage(error, name: name)
                DispatchQueue.main.async {
                    guard let self = self, self.capture?.id == state.id else { return }
                    self.captureFailed(message)
                }
            }
        }
    }

    static func captureErrorMessage(_ error: Error, name: String) -> String {
        guard let error = error as? CrossDropError else { return "Couldn't ask \(name). Try again." }
        switch error.code {
        case ErrorCode.declined: return "\(name) declined the request."
        case ErrorCode.unreachable:
            return "Couldn't reach \(name). Open CrossDrop on it and check both are on the same Wi-Fi."
        case ErrorCode.notReceiving: return "Receiving is off on \(name)."
        case ErrorCode.pairingRequired: return "\(name) doesn't recognise this Mac any more. Pair them again."
        case ErrorCode.timeout: return "\(name) didn't answer in time."
        case ErrorCode.badMessage, ErrorCode.unexpectedMessage:
            return "\(name) can't take photo requests yet. Update CrossDrop on it."
        default: return TransferText.message(for: error, peer: name)
        }
    }

    private func armCaptureTimeout() {
        captureTimer?.invalidate()
        guard let state = capture else { return }
        let timer = Timer(timeInterval: ProtocolConstants.captureRequestTTL, repeats: false) { [weak self] _ in
            guard let self = self, self.capture?.id == state.id, self.capture?.phase == .waiting else { return }
            self.captureFailed("No photo arrived from \(state.deviceName). Ask again when you're ready.")
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
    }

    /// Stops waiting; a photo sent afterwards is treated like any other incoming offer.
    func cancelCapture() {
        if let requestId = capture?.requestId { server?.captureRequests.cancel(requestId) }
        captureTimer?.invalidate()
        captureTimer = nil
        captureAfterReady = nil
        capture = nil
    }

    private func captureFailed(_ message: String, requestId: String? = nil) {
        guard let current = capture else { return }
        if let requestId = requestId, current.requestId != requestId { return }
        if let id = current.requestId { server?.captureRequests.cancel(id) }
        captureTimer?.invalidate()
        captureTimer = nil
        captureAfterReady = nil
        capture?.phase = .failed(message)
        show(message)
        notify(title: current.title, body: message)
    }

    /// An incoming transfer that answers a request this Mac sent (the core sets `requestId`
    /// only when it matched one of ours, from that same phone).
    private func isCaptureReply(_ snapshot: TransferSnapshot) -> Bool {
        snapshot.direction == .incoming && snapshot.kind == .files && snapshot.requestId != nil
    }

    private func deliverCapture(_ urls: [URL], peerName: String, requestId: String?) {
        let allImages = urls.allSatisfy { UTType(filenameExtension: $0.pathExtension.lowercased())?.conforms(to: .image) ?? false }
        let what = allImages ? (urls.count == 1 ? "Photo" : "\(urls.count) photos")
                             : (urls.count == 1 ? "File" : "\(urls.count) files")
        if let count = PasteboardFiles.copy(urls) {
            clipboardWatcher.ignore(changeCount: count)
        }
        let text = "\(what) from \(peerName) \u{2014} ready to paste"
        show(text, action: .reveal(urls))
        if notificationsEnabled, !NSApp.isActive {
            NotificationManager.shared.postReady(title: text, body: "Press \u{2318}V in any app.", urls: urls)
        }
        if let current = capture, requestId == nil || current.requestId == requestId {
            captureTimer?.invalidate()
            captureTimer = nil
            capture = nil
        }
    }

    // MARK: - Drip Rooms (§9.9)

    /// The room a discovered device's TXT hints point at (a hint only; pairing proves it).
    func room(forHints hints: [String]) -> Room? {
        for hint in hints {
            if let room = rooms.room(forHint: hint) { return room }
        }
        return nil
    }

    func room(for device: DiscoveredDevice) -> Room? {
        room(forHints: device.roomHints)
    }

    /// Nearby devices that advertise the current room.
    var roomDevicesNearby: [DiscoveredDevice] {
        nearby.filter { room(for: $0) != nil }
    }

    /// Devices trusted through the current room (temporary trust ending with it).
    var roomMembers: [TrustedDeviceRecord] {
        guard let room = currentRoom else { return [] }
        return trustedDevices.filter { record in
            guard let end = record.expiresAt else { return false }
            return abs(end.timeIntervalSince(room.expiryDate)) < 2
        }
    }

    /// Hosting needs the receiver on (any mode; "My Devices" accepts room members).
    var canHostRoom: Bool { receivingEnabled }

    /// Starts a room this Mac hosts. Shows its code with `roomInviteURI()`.
    @discardableResult
    func startRoom(name: String, duration: RoomDuration) -> Bool {
        guard receivingEnabled else {
            show("Turn on receiving to host a room. My Devices is enough: room members can still join.",
                 action: .useMyDevices)
            return false
        }
        if currentRoom != nil { endRoom() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = trimmed.isEmpty ? "\(deviceName)\u{2019}s room" : String(trimmed.prefix(64))
        guard let room = rooms.create(name: roomName, ttl: duration.rawValue) else {
            show("Couldn't start the room. Try again.")
            return false
        }
        currentRoom = room
        roomIsHosted = true
        server?.refreshAdvertisement()
        scheduleRoomEnd(room)
        refreshNearby()
        return true
    }

    /// The room's QR code text: name, key, expiry and how to reach this Mac (IPv4 addresses,
    /// listening port, key fingerprint). Anyone who sees it can join until it ends.
    func roomInviteURI() -> String? {
        guard let room = currentRoom, room.isActive(), let port = listeningPort else { return nil }
        let hosts = Array(Self.localIPv4Addresses().prefix(4))
        guard !hosts.isEmpty else { return nil }
        return RoomInvite(room: room, hosts: hosts, port: port, fingerprint: identity.fingerprint)?.uri
    }

    /// Joins a room from its code text (pasted). Returns false for an invalid or ended room.
    @discardableResult
    func joinRoom(inviteURI: String) -> Bool {
        guard let invite = RoomInvite.parse(inviteURI.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            show("That isn't a valid room code, or the room has already ended.")
            return false
        }
        if currentRoom != nil { endRoom() }
        guard rooms.join(invite.room) else {
            show("That room has already ended.")
            return false
        }
        currentRoom = invite.room
        roomIsHosted = false
        server?.refreshAdvertisement()
        scheduleRoomEnd(invite.room)
        refreshNearby()
        return true
    }

    /// Ends the room now. The temporary trust its members got on this Mac ends with it.
    func endRoom() {
        guard let room = currentRoom else { return }
        rooms.leave(id: room.id)
        let members = roomMembers
        currentRoom = nil
        roomIsHosted = false
        roomTimer?.invalidate()
        roomTimer = nil
        for member in members { trustStore.forget(member.deviceId) }
        server?.refreshAdvertisement()
        refreshNearby()
    }

    private func scheduleRoomEnd(_ room: Room) {
        roomTimer?.invalidate()
        let roomId = room.id
        let timer = Timer(fire: room.expiryDate.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            self?.roomEnded(roomId)
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        roomTimer = timer
    }

    private func roomEnded(_ roomId: String) {
        guard currentRoom?.id == roomId else { return }
        rooms.purgeExpired()
        rooms.leave(id: roomId)
        currentRoom = nil
        roomIsHosted = false
        roomTimer = nil
        server?.refreshAdvertisement()
        purgeExpiredTrust()
        refreshNearby()
        show("The room has ended. Its members are no longer trusted on this Mac.")
    }

    /// One timer at the next moment a temporary trust ends (rooms), nothing while there is none.
    private func scheduleTrustPurge() {
        trustPurgeTimer?.invalidate()
        trustPurgeTimer = nil
        guard let next = trustStore.nextExpiry else { return }
        let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            self?.purgeExpiredTrust()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        trustPurgeTimer = timer
    }

    private func purgeExpiredTrust() {
        if !trustStore.purgeExpired() { scheduleTrustPurge() }
    }

    // MARK: - Offer what I copy to my phone

    /// True while the clipboard is being watched (setting on and your phone found nearby).
    @Published private(set) var clipboardWatching = false

    /// The phone copied text goes to: paired permanently, marked "This is my device", and
    /// found by discovery right now. Never a remembered address: another device may hold it
    /// by now, and the core doesn't refuse a different (trusted) device answering there.
    /// Discovery runs only while CrossDrop's window or menu bar panel is open.
    var clipboardTarget: DiscoveredDevice? {
        nearby.first { !$0.isRemembered && isMyPhone($0.deviceId) }
    }

    func setOfferClipboardToPhone(_ enabled: Bool) {
        offerClipboardToPhone = enabled
        AppSettings.offerClipboard = enabled
        clipboardOfferStatus = nil
        updateClipboardWatcher()
    }

    /// The 1.5 s change-count check runs only while the setting is on and discovery sees the phone.
    private func updateClipboardWatcher() {
        let shouldRun = offerClipboardToPhone && clipboardTarget != nil
        if shouldRun, !clipboardWatcher.isRunning {
            clipboardWatcher.start()
        } else if !shouldRun, clipboardWatcher.isRunning {
            clipboardWatcher.stop()
        }
        if clipboardWatching != shouldRun { clipboardWatching = shouldRun }
    }

    private func offerCopiedText(_ text: String) {
        guard offerClipboardToPhone, let target = clipboardTarget else { return }
        startTransfer(files: [OutgoingFile.text(text, name: "Text")], to: target, kind: .text,
                      options: SendOptions(quiet: true))
    }

    /// Clipboard sends leave no card or history; only the setting's footnote changes.
    private func handleQuietUpdate(_ snapshot: TransferSnapshot) {
        // The phone was paired as "mine"; a pairing request, or another device answering the
        // handshake, means it isn't the phone: stop before the text is offered.
        if !snapshot.phase.isFinished, snapshot.phase == .pairing || wrongPeer(snapshot) {
            outgoing[snapshot.id]?.cancel()
            return
        }
        guard snapshot.phase.isFinished else { return }
        let mismatched = wrongPeer(snapshot)
        quietIds.remove(snapshot.id)
        expectedPeers[snapshot.id] = nil
        let time = Date().formatted(date: .omitted, time: .shortened)
        if mismatched {
            clipboardOfferStatus = "The last copy wasn\u{2019}t sent: a different device answered (\(time))."
            return
        }
        switch snapshot.phase {
        case .completed:
            clipboardOfferStatus = "Last copy sent to \(snapshot.peerName) at \(time)."
        case .rejected:
            clipboardOfferStatus = "\(snapshot.peerName) declined the last copy (\(time))."
        default:
            clipboardOfferStatus = "The last copy didn't reach \(snapshot.peerName) (\(time))."
        }
    }

    // MARK: - After a transfer arrives: sorting, expiring drops, photo to clipboard

    /// Runs once an incoming file transfer is verified: "Sort by type" moves, HEIC→JPEG copies,
    /// expiring-drop bookkeeping and the clipboard for a requested photo. File work runs off
    /// the main thread; the model is updated back on it.
    private func postProcessIncoming(_ snapshot: TransferSnapshot, entryDeletesAt: Date?, captureReply: Bool) {
        let transferId = snapshot.id
        let peerName = snapshot.peerName
        let requestId = snapshot.requestId
        let saved: [(index: Int, url: URL, inFolder: Bool)] = snapshot.files.enumerated().compactMap { pair -> (index: Int, url: URL, inFolder: Bool)? in
            guard let url = pair.element.savedURL else { return nil }
            // A folder transfer's files carry their folders in the name ("Trip/IMG_1.jpg").
            return (pair.offset, url, pair.element.name.contains("/"))
        }
        guard !saved.isEmpty else { return }
        let sort = sortByType
        let heic = heicToJpeg
        let now = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var moves: [(index: Int, from: URL, to: URL)] = []
            var finals: [URL] = []
            for item in saved {
                var location = item.url
                if sort, !item.inFolder,
                   let folder = SmartArrival.folder(for: item.url, deviceName: peerName, date: now),
                   let moved = SmartArrival.move(item.url, into: folder) {
                    moves.append((item.index, item.url, moved))
                    location = moved
                }
                finals.append(location)
            }
            let copies = heic ? HeicConverter.saveJpegCopies(of: finals) : []
            DispatchQueue.main.async {
                self?.finishIncoming(transferId: transferId, peerName: peerName, moves: moves, finals: finals,
                                     extras: copies, deletesAt: entryDeletesAt, captureReply: captureReply,
                                     requestId: requestId)
            }
        }
    }

    private func finishIncoming(transferId: String, peerName: String, moves: [(index: Int, from: URL, to: URL)],
                                finals: [URL], extras: [URL], deletesAt: Date?, captureReply: Bool, requestId: String?) {
        if !moves.isEmpty {
            for move in moves { relocated[move.from.path] = move.to }
            historyStore.update(id: transferId) { entry in
                for move in moves where entry.files.indices.contains(move.index) {
                    entry.files[move.index].path = move.to.path
                }
            }
            history = historyStore.entries
        }
        if let deletesAt = deletesAt {
            registerExpiring(finals + extras, transferId: transferId, deleteAt: deletesAt)
        }
        if captureReply {
            deliverCapture(finals, peerName: peerName, requestId: requestId)
        }
    }

    // MARK: - Expiring drops (§9.8)

    /// How often waiting expiring drops are checked at most (one timer, only while there are any).
    static let expiryCheckInterval: TimeInterval = 15 * 60

    private func registerExpiring(_ urls: [URL], transferId: String, deleteAt: Date) {
        var registered = 0
        for url in urls {
            guard let identity = ExpiringFile.identity(of: url) else { continue }
            expiringFiles.append(ExpiringFile(id: UUID(), transferId: transferId, path: url.path,
                                              size: identity.size, deleteAt: deleteAt,
                                              fileNumber: identity.fileNumber, modifiedAt: identity.modifiedAt))
            registered += 1
        }
        if registered == 0 {
            // Nothing could be tracked, so nothing will be deleted: say so instead of a date.
            historyStore.update(id: transferId) { entry in
                entry.deletesAt = nil
                entry.notDeletedReason = "Not deleted: the files couldn\u{2019}t be tracked"
            }
            history = historyStore.entries
            return
        }
        expiringFile.save(expiringFiles)
        scheduleExpiryTimer()
    }

    /// Moves due expiring drops to the Trash (recoverable there), skipping any file that was
    /// moved, deleted or replaced since it arrived (see `ExpiringFile.isUnchanged`). History
    /// says "Moved to Trash" only for transfers whose files really went there.
    func checkExpiringFiles() {
        let now = Date()
        let due = expiringFiles.filter { $0.deleteAt <= now }
        guard !due.isEmpty else {
            scheduleExpiryTimer()
            return
        }
        let dueIds = Set(due.map { $0.id })
        expiringFiles.removeAll { dueIds.contains($0.id) }
        expiringFile.save(expiringFiles)
        // Transfers with no files left waiting: their outcome is settled now.
        let finished = Set(due.map { $0.transferId }).filter { id in !expiringFiles.contains { $0.transferId == id } }
        var unchanged: [String: [URL]] = [:]
        for file in due where file.isUnchanged {
            unchanged[file.transferId, default: []].append(URL(fileURLWithPath: file.path))
        }
        let candidates = unchanged
        let urls = candidates.values.flatMap { $0 }
        let settle: (Set<String>, Bool) -> Void = { [weak self] trashedPaths, failed in
            guard let self = self else { return }
            var refused = 0
            for id in finished {
                let tried = candidates[id] ?? []
                let trashed = tried.filter { trashedPaths.contains($0.standardizedFileURL.path) }
                refused += tried.count - trashed.count
                self.historyStore.update(id: id) { entry in
                    if !trashed.isEmpty {
                        entry.deletedAt = Date()
                    } else {
                        entry.deletesAt = nil
                        entry.notDeletedReason = tried.isEmpty
                            ? "Not deleted: the files were moved or changed"
                            : "Not deleted: couldn\u{2019}t move them to the Trash"
                    }
                }
            }
            self.history = self.historyStore.entries
            if failed, refused > 0 {
                self.show(refused == 1 ? "An expired file couldn\u{2019}t be moved to the Trash. It\u{2019}s still where it was saved."
                                       : "\(refused) expired files couldn\u{2019}t be moved to the Trash. They\u{2019}re still where they were saved.")
            }
        }
        if urls.isEmpty {
            settle([], false)
        } else {
            NSWorkspace.shared.recycle(urls) { newURLs, error in
                let trashed = Set(newURLs.keys.map { $0.standardizedFileURL.path })
                DispatchQueue.main.async { settle(trashed, error != nil) }
            }
        }
        scheduleExpiryTimer()
    }

    /// Keeps an expiring drop: its files are no longer moved to the Trash.
    func keepFiles(of entry: HistoryEntry) {
        expiringFiles.removeAll { $0.transferId == entry.id }
        expiringFile.save(expiringFiles)
        historyStore.update(id: entry.id) { $0.deletesAt = nil }
        history = historyStore.entries
        scheduleExpiryTimer()
        show("Kept. These files won't be deleted.")
    }

    private func scheduleExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let earliest = expiringFiles.map({ $0.deleteAt }).min() else { return }
        let now = Date()
        let fire = min(max(earliest, now.addingTimeInterval(5)), now.addingTimeInterval(Self.expiryCheckInterval))
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in self?.checkExpiringFiles() }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: - Settings (island, sorting, Turbo)

    func setDripIsland(_ enabled: Bool) {
        dripIslandEnabled = enabled
        AppSettings.dripIsland = enabled
    }

    func setSortByType(_ enabled: Bool) {
        sortByType = enabled
        AppSettings.sortByType = enabled
    }

    func setTurbo(_ enabled: Bool) {
        turboEnabled = enabled
        AppSettings.turbo = enabled
    }

    // MARK: - Notices

    func show(_ text: String, action: NoticeAction? = nil) {
        let notice = Notice(text: text, action: action)
        self.notice = notice
        // A toast with a button stays a little longer, so there is time to press it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 5 : 9)) { [weak self] in
            if self?.notice == notice { self?.notice = nil }
        }
    }

    /// Runs the button on a toast.
    func performNoticeAction(_ notice: Notice) {
        guard let action = notice.action else { return }
        if self.notice == notice { self.notice = nil }
        switch action {
        case .reveal(let urls):
            reveal(urls)
        case .useMyDevices:
            if capture?.phase == .needsReceiving {
                allowCaptureReplies()
            } else {
                setReceiveMode(.mine)
            }
        case .sendWhenNearby(let transferId):
            if let item = transfers.first(where: { $0.id == transferId }) {
                sendWhenNearby(item)
            }
        }
    }

    // MARK: - CrossDropDelegate (background threads)

    func crossDropPairingRequested(_ prompt: PairingPrompt, decision: Decision) {
        DispatchQueue.main.async {
            // Already answered: a silent send (clipboard, queue) reached an unknown device and
            // was cancelled on its `.pairing` snapshot, which arrives here first. No window,
            // no prompt that would vanish a moment later.
            guard !decision.isFinished else { return }
            self.prompts.append(.pairing(prompt, decision))
            self.requestMainWindow()
            if prompt.role == .receiver {
                self.notify(title: "Pairing request", body: "A nearby device wants to pair with this Mac.")
            }
        }
    }

    func crossDropPairingFinished(id: String, success: Bool) {
        DispatchQueue.main.async {
            self.prompts.removeAll { $0.id == "pair-" + id }
            self.waitingPairingIds.remove(id)
        }
    }

    func crossDropOfferReceived(_ offer: OfferPrompt, decision: Decision) {
        DispatchQueue.main.async {
            self.prompts.append(.offer(offer, decision))
            self.requestMainWindow()
            let what: String
            switch offer.kind {
            case .link: what = "a link"
            case .text: what = "some text"
            case .files: what = offer.files.count == 1 ? "a file" : "\(offer.files.count) files"
            }
            if self.notificationsEnabled, !NSApp.isActive {
                NotificationManager.shared.postOffer(transferId: offer.transferId, title: "Incoming from \(offer.peer.name)",
                                                     body: "\(offer.peer.name) wants to send you \(what).")
            }
        }
    }

    func crossDropOfferFinished(transferId: String) {
        DispatchQueue.main.async {
            NotificationManager.shared.removeOffer(transferId: transferId)
            self.prompts.removeAll { $0.id == "offer-" + transferId }
        }
    }

    func crossDropTransferUpdated(_ snapshot: TransferSnapshot) {
        DispatchQueue.main.async { self.upsert(snapshot) }
    }

    /// This Mac does not take photos for other devices (§9.7): always declined.
    func crossDropCaptureRequested(_ request: CaptureRequest) -> Bool { false }

    private func upsert(_ snapshot: TransferSnapshot) {
        if quietIds.contains(snapshot.id) {
            handleQuietUpdate(snapshot)
            return
        }
        if let queueId = queueAttempts[snapshot.id], !handleQueueUpdate(snapshot, queueId: queueId) {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let index = transfers.firstIndex(where: { $0.id == snapshot.id }) {
            transfers[index].update(snapshot, now: now)
        } else {
            transfers.insert(TransferItem(snapshot, now: now), at: 0)
        }
        if snapshot.phase.isFinished, !recordedIds.contains(snapshot.id) {
            recordedIds.insert(snapshot.id)
            record(snapshot)
            if snapshot.direction == .incoming, snapshot.phase == .completed, receivingEnabled {
                scheduleAutoOff()
            }
            if snapshot.direction == .incoming, snapshot.phase == .completed, let peerId = snapshot.peerId,
               sendQueue.contains(where: { $0.deviceId == peerId }) {
                // It just reached us, so it is around: deliver what was waiting for it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.deliverQueue(for: peerId, force: true)
                }
            }
            offerQueueIfUnreachable(snapshot)
        }
    }

    private func record(_ snapshot: TransferSnapshot) {
        let link: String? = snapshot.kind == .link ? (snapshot.text ?? sentText[snapshot.id]).map { String($0.prefix(2048)) } : nil
        let captureReply = isCaptureReply(snapshot)
        var entry = HistoryEntry(
            id: snapshot.id, direction: snapshot.direction.rawValue, peerName: snapshot.peerName,
            platform: snapshot.peerPlatform ?? "android", status: snapshot.phase.rawValue,
            files: snapshot.files.map { HistoryFile(name: $0.name, size: $0.size, path: ($0.savedURL ?? $0.sourceURL)?.path) },
            totalBytes: snapshot.totalBytes, finishedAt: Date(), errorCode: snapshot.error?.code,
            kind: snapshot.kind.rawValue, link: link)
        entry.expiresAfter = snapshot.expiresAfter
        if snapshot.direction == .incoming, snapshot.phase == .completed, snapshot.kind == .files,
           let seconds = snapshot.expiresAfter {
            entry.deletesAt = Date().addingTimeInterval(TimeInterval(seconds))
        }
        if captureReply { entry.isCaptureReply = true }
        historyStore.add(entry)
        history = historyStore.entries

        if snapshot.kind != .files {
            handleHandoff(snapshot)
            return
        }
        if captureReply, snapshot.phase != .completed {
            captureFailed("The photo from \(snapshot.peerName) didn't arrive. \(TransferText.errorMessage(snapshot))",
                          requestId: snapshot.requestId)
        }
        if snapshot.direction == .incoming, snapshot.phase == .completed {
            postProcessIncoming(snapshot, entryDeletesAt: entry.deletesAt, captureReply: captureReply)
        }

        let count = snapshot.files.count
        let noun = count == 1 ? "file" : "\(count) files"
        if snapshot.phase == .completed {
            if soundOnDone { DoneSound.play() }
            Haptics.success()
            // A photo for the clipboard gets its own "ready to paste" toast instead.
            if !captureReply { celebrate(snapshot) }
        }
        switch (snapshot.direction, snapshot.phase) {
        case (.incoming, .completed):
            if !captureReply {
                notify(title: "Received \(noun)", body: "From \(snapshot.peerName). Saved and verified.")
            }
        case (.outgoing, .completed):
            notify(title: "Sent \(noun)", body: "Delivered to \(snapshot.peerName).")
        case (_, .failed):
            notify(title: "Transfer failed", body: TransferText.errorMessage(snapshot))
        default:
            break
        }
    }

    /// A link or text arrived (§9.2): links open in the browser (http/https only), text
    /// goes to the clipboard. The sender was approved (or is auto-accepted) like any offer.
    private func handleHandoff(_ snapshot: TransferSnapshot) {
        guard snapshot.phase == .completed else {
            if snapshot.phase == .failed { notify(title: "Transfer failed", body: TransferText.errorMessage(snapshot)) }
            return
        }
        if soundOnDone { DoneSound.play() }
        Haptics.success()
        if snapshot.direction == .outgoing {
            show(snapshot.kind == .link ? "Link sent to \(snapshot.peerName)." : "Text sent to \(snapshot.peerName).")
            return
        }
        guard let text = snapshot.text else { return }
        if snapshot.kind == .link, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil {
            NSWorkspace.shared.open(url)
            show("Opened a link from \(snapshot.peerName).")
            notify(title: "Link from \(snapshot.peerName)", body: "Opened in your browser.")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            // Never offer it straight back to the phone it came from.
            clipboardWatcher.ignore(changeCount: NSPasteboard.general.changeCount)
            show("Copied text from \(snapshot.peerName) to the clipboard.")
            notify(title: "Text from \(snapshot.peerName)", body: "Copied to the clipboard.")
        }
    }

    private func celebrate(_ snapshot: TransferSnapshot) {
        let noun = Format.files(snapshot.files.count)
        let message = snapshot.direction == .outgoing
            ? "\(noun) arrived on \(snapshot.peerName) and passed the integrity check."
            : "\(noun) from \(snapshot.peerName) saved and passed the integrity check."
        let item = Celebration(id: UUID(), message: message)
        celebration = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            if self?.celebration?.id == item.id { self?.celebration = nil }
        }
    }

    private func notify(title: String, body: String) {
        guard notificationsEnabled, !NSApp.isActive else { return }
        NotificationManager.shared.post(title: title, body: body)
    }
}

struct Celebration: Equatable {
    let id: UUID
    let message: String
}
