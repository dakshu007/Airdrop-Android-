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
    private var retryInfo: [String: (files: [OutgoingFile], deviceId: String, kind: OfferKind)] = [:]
    /// Link / text sent per transfer id, kept for history ("Send again" for links).
    private var sentText: [String: String] = [:]
    private var recordedIds: Set<String> = []
    private var autoOffTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var networkSignature: String?
    private var started = false

    private init() {
        let loaded = IdentityStore.loadOrCreate()
        identity = loaded.0
        identityLocation = loaded.1
        let mode = ReceiveMode(rawValue: AppSettings.receiveMode) ?? .everyone
        receiveMode = mode
        receivingEnabled = mode != .off
        heicToJpeg = AppSettings.heicToJpeg
        deviceName = AppSettings.deviceName
        destination = AppSettings.destination
        autoOffMinutes = AppSettings.autoOffMinutes
        notificationsEnabled = AppSettings.notificationsEnabled
        soundOnDone = AppSettings.soundOnDone
        trustedDevices = trustStore.all
        history = historyStore.entries
        trustStore.onChange = { [weak self] list in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let before = Set(self.trustedDevices.map(\.deviceId))
                self.trustedDevices = list
                self.refreshNearby()
                // A new pairing while the QR sheet is up: that's the phone that scanned it.
                if self.showingPairSheet, let added = list.first(where: { !before.contains($0.deviceId) }) {
                    self.showingPairSheet = false
                    self.show("Paired with \(added.name).")
                }
            }
        }
        privateFlag.set(mode == .mine)
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
        startPathMonitor()
        if receivingEnabled { startServer() }
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
            destination: { AppSettings.destination }, privateMode: { flag.get() }))
        server.delegate = self
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
        case .localNetworkDenied: receiverStatus = .localNetworkDenied
        case .failed:
            if usePreferredPort {
                // The stable port is taken (another app, or a second copy): any free port works too.
                usePreferredPort = false
                startServer()
                return
            }
            receiverStatus = .failed("Receiving stopped unexpectedly.")
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
        discovered = devices
        refreshNearby()
    }

    /// Discovered devices (private ones only when paired), plus paired devices that
    /// discovery can't see but that answered at a known address before.
    private func refreshNearby() {
        let trusted = Dictionary(trustedDevices.map { ($0.deviceId, $0) }, uniquingKeysWith: { a, _ in a })
        var devices = discovered.filter { !$0.isPrivate || trusted[$0.deviceId] != nil }.map { device -> DiscoveredDevice in
            guard let record = trusted[device.deviceId] else { return device }
            // Show the name the user knows (a private device advertises a random one).
            return DiscoveredDevice(deviceId: device.deviceId, name: record.name, platform: device.platform,
                                    endpoint: device.endpoint, isPrivate: device.isPrivate)
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
    }

    /// Devices found by discovery right now (not counting remembered ones).
    @Published private(set) var discoveredCount = 0

    func isTrusted(_ deviceId: String) -> Bool {
        trustedDevices.contains { $0.deviceId == deviceId }
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
    }

    func handleWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.restartNetworking()
        }
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
        let type = UTType.fileURL.identifier
        for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
            provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let fileURL = url else { return }
                DispatchQueue.main.async { self?.addFiles([fileURL]) }
            }
        }
    }

    func addFiles(_ urls: [URL]) {
        var added = 0
        var skipped = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { skipped += 1; continue }
            if values?.isDirectory == true {
                let (count, rest) = addFolder(url)
                added += count
                skipped += rest
                continue
            }
            if add(url, path: []) { added += 1 }
        }
        if selectedFiles.count > ProtocolConstants.maxFilesPerOffer {
            selectedFiles = Array(selectedFiles.prefix(ProtocolConstants.maxFilesPerOffer))
            show("Up to \(ProtocolConstants.maxFilesPerOffer) files can go in one send; the rest were left out.")
        } else if skipped > 0 {
            show(skipped == 1 ? "1 item was skipped (a link or an unreadable file)."
                              : "\(skipped) items were skipped (links or unreadable files).")
        }
        if added > 0 { pendingText = nil }
    }

    /// Adds every regular file under `folder`, keeping its structure (§9.1).
    /// Hidden files and symbolic links are skipped.
    private func addFolder(_ folder: URL) -> (added: Int, skipped: Int) {
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
            if add(url, path: path) { added += 1 }
        }
        return (added, skipped)
    }

    private func add(_ url: URL, path: [String]) -> Bool {
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
        if let text = pendingText {
            let name = text.kind == .link ? "Link" : "Text"
            for device in devices {
                startTransfer(files: [OutgoingFile.text(text.text, name: name)], to: device, kind: text.kind,
                              text: text.kind == .link ? text.text : nil)
            }
            pendingText = nil
        } else {
            guard !selectedFiles.isEmpty else { return }
            let files = selectedFiles.map { file in
                OutgoingFile(url: file.url, name: file.name,
                             mime: UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType,
                             path: file.path)
            }
            for device in devices { startTransfer(files: files, to: device) }
            selectedFiles.removeAll()
        }
        multiSelecting = false
        multiSelection.removeAll()
    }

    /// Sends the clipboard to one device straight away (menu bar shortcut).
    func sendClipboard(to device: DiscoveredDevice) {
        guard takeClipboard() else { return }
        sendSelection(to: [device])
    }

    private func startTransfer(files: [OutgoingFile], to device: DiscoveredDevice, kind: OfferKind = .files,
                               text: String? = nil) {
        let transfer = OutgoingTransfer(endpoint: device.endpoint, peerName: device.name, peerId: device.deviceId,
                                        peerPlatform: device.platform, files: files, identity: identity,
                                        local: localInfo, trust: trustStore, delegate: self, kind: kind)
        outgoing[transfer.id] = transfer
        retryInfo[transfer.id] = (files, device.deviceId, kind)
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
    }

    func retry(_ item: TransferItem) {
        guard let info = retryInfo[item.id] else { return }
        guard let device = nearby.first(where: { $0.deviceId == info.deviceId }) else {
            show("\(item.snapshot.peerName) isn't nearby right now. Open CrossDrop on it and turn on Receiving.")
            return
        }
        transfers.removeAll { $0.id == item.id }
        startTransfer(files: info.files, to: device, kind: info.kind, text: sentText[item.id])
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

    func clearHistory() {
        historyStore.clear()
        history = []
    }

    func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
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

    // MARK: - Notices

    func show(_ text: String) {
        let notice = Notice(text: text)
        self.notice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if self?.notice == notice { self?.notice = nil }
        }
    }

    // MARK: - CrossDropDelegate (background threads)

    func crossDropPairingRequested(_ prompt: PairingPrompt, decision: Decision) {
        DispatchQueue.main.async {
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

    private func upsert(_ snapshot: TransferSnapshot) {
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
        }
    }

    private func record(_ snapshot: TransferSnapshot) {
        let link: String? = snapshot.kind == .link ? (snapshot.text ?? sentText[snapshot.id]).map { String($0.prefix(2048)) } : nil
        let entry = HistoryEntry(
            id: snapshot.id, direction: snapshot.direction.rawValue, peerName: snapshot.peerName,
            platform: snapshot.peerPlatform ?? "android", status: snapshot.phase.rawValue,
            files: snapshot.files.map { HistoryFile(name: $0.name, size: $0.size, path: ($0.savedURL ?? $0.sourceURL)?.path) },
            totalBytes: snapshot.totalBytes, finishedAt: Date(), errorCode: snapshot.error?.code,
            kind: snapshot.kind.rawValue, link: link)
        historyStore.add(entry)
        history = historyStore.entries

        if snapshot.kind != .files {
            handleHandoff(snapshot)
            return
        }
        if snapshot.direction == .incoming, snapshot.phase == .completed, heicToJpeg {
            let urls = snapshot.files.compactMap { $0.savedURL }
            DispatchQueue.global(qos: .utility).async { HeicConverter.saveJpegCopies(of: urls) }
        }

        let count = snapshot.files.count
        let noun = count == 1 ? "file" : "\(count) files"
        if snapshot.phase == .completed {
            if soundOnDone { DoneSound.play() }
            celebrate(snapshot)
        }
        switch (snapshot.direction, snapshot.phase) {
        case (.incoming, .completed):
            notify(title: "Received \(noun)", body: "From \(snapshot.peerName). Saved and verified.")
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
