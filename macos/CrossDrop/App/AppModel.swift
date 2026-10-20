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
    @Published private(set) var receiverStatus: ReceiverStatus = .off
    @Published private(set) var discoveryStatus: DiscoveryStatus = .idle
    @Published private(set) var nearby: [DiscoveredDevice] = []
    @Published private(set) var networkAvailable = true

    // Sending
    @Published var selectedFiles: [SelectedFile] = []
    @Published var selectedDeviceId: String?
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
    @Published private(set) var wallpaper: Wallpaper

    // UI
    @Published var selectedTab: AppTab = .send
    @Published var notice: Notice?
    @Published private(set) var windowRequest = 0

    let identity: DeviceIdentity
    let identityLocation: IdentityStore.Location
    let trustStore = TrustStore()
    private let historyStore = HistoryStore()

    private var server: CrossDropServer?
    private lazy var browser: BonjourBrowser = makeBrowser()
    private var discoveryClients = 0
    private var outgoing: [String: OutgoingTransfer] = [:]
    private var retryInfo: [String: (files: [OutgoingFile], deviceId: String)] = [:]
    private var recordedIds: Set<String> = []
    private var autoOffTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var networkSignature: String?
    private var started = false

    private init() {
        let loaded = IdentityStore.loadOrCreate()
        identity = loaded.0
        identityLocation = loaded.1
        receivingEnabled = AppSettings.receivingEnabled
        deviceName = AppSettings.deviceName
        destination = AppSettings.destination
        autoOffMinutes = AppSettings.autoOffMinutes
        notificationsEnabled = AppSettings.notificationsEnabled
        wallpaper = Wallpaper(rawValue: AppSettings.wallpaper) ?? .dusk
        trustedDevices = trustStore.all
        history = historyStore.entries
        trustStore.onChange = { [weak self] list in
            DispatchQueue.main.async { self?.trustedDevices = list }
        }
    }

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        NotificationManager.shared.onOpen = { [weak self] in self?.requestMainWindow() }
        startPathMonitor()
        if receivingEnabled { startServer() }
    }

    private var localInfo: LocalInfo {
        LocalInfo(name: deviceName, platform: "macos", appVersion: Self.appVersion)
    }

    // MARK: - Receiving

    func setReceiving(_ enabled: Bool) {
        guard enabled != receivingEnabled else { return }
        receivingEnabled = enabled
        AppSettings.receivingEnabled = enabled
        if enabled {
            if notificationsEnabled { NotificationManager.shared.requestAuthorization { _ in } }
            startServer()
        } else {
            stopServer()
            receiverStatus = .off
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
        let server = CrossDropServer(configuration: .init(
            identity: identity, local: localInfo, trust: trustStore,
            destination: { AppSettings.destination }))
        server.delegate = self
        server.onStateChange = { [weak self, weak server] state in
            DispatchQueue.main.async {
                guard let self = self, let server = server, self.server === server else { return }
                self.apply(state)
            }
        }
        do {
            try server.start(port: nil, advertise: true)
            self.server = server
            receiverStatus = .starting
        } catch {
            receiverStatus = .failed("Couldn't start listening.")
        }
        scheduleAutoOff()
    }

    private func stopServer() {
        server?.stop()
        server = nil
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDate = nil
    }

    private func apply(_ state: CrossDropServer.State) {
        switch state {
        case .stopped: receiverStatus = receivingEnabled ? .starting : .off
        case .starting: receiverStatus = .starting
        case .ready: receiverStatus = .ready
        case .localNetworkDenied: receiverStatus = .localNetworkDenied
        case .failed: receiverStatus = .failed("Receiving stopped unexpectedly.")
        }
    }

    private func scheduleAutoOff() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDate = nil
        guard receivingEnabled, autoOffMinutes > 0 else { return }
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
        setReceiving(false)
        show("Receiving turned off to save energy.")
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
        nearby = devices
        if let selected = selectedDeviceId, !devices.contains(where: { $0.deviceId == selected }) {
            selectedDeviceId = nil
        }
        if selectedDeviceId == nil, devices.count == 1 {
            selectedDeviceId = devices[0].deviceId
        }
    }

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
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to send. Folders aren't supported yet."
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
        var skippedFolders = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey])
            if values?.isDirectory == true {
                skippedFolders += 1
                continue
            }
            guard values?.isRegularFile ?? true else { continue }
            if selectedFiles.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { continue }
            selectedFiles.append(SelectedFile(url: url, name: url.lastPathComponent, size: Int64(values?.fileSize ?? 0)))
        }
        if skippedFolders > 0 {
            show(skippedFolders == 1 ? "Folders aren't supported yet. Add the files inside it instead."
                                     : "\(skippedFolders) folders were skipped. Folders aren't supported yet.")
        }
    }

    func removeFile(_ file: SelectedFile) {
        selectedFiles.removeAll { $0.id == file.id }
    }

    func clearSelection() {
        selectedFiles.removeAll()
    }

    var selectedTotalBytes: Int64 {
        selectedFiles.reduce(0) { $0 + $1.size }
    }

    // MARK: - Sending

    func sendSelection(to device: DiscoveredDevice) {
        guard !selectedFiles.isEmpty else { return }
        let files = selectedFiles.map { file in
            OutgoingFile(url: file.url, name: file.name,
                         mime: UTType(filenameExtension: file.url.pathExtension)?.preferredMIMEType)
        }
        startTransfer(files: files, to: device)
        selectedFiles.removeAll()
    }

    private func startTransfer(files: [OutgoingFile], to device: DiscoveredDevice) {
        let transfer = OutgoingTransfer(endpoint: device.endpoint, peerName: device.name, peerId: device.deviceId,
                                        peerPlatform: device.platform, files: files, identity: identity,
                                        local: localInfo, trust: trustStore, delegate: self)
        outgoing[transfer.id] = transfer
        retryInfo[transfer.id] = (files, device.deviceId)
        upsert(transfer.snapshot)
        Task.detached { [weak self] in
            _ = await transfer.run()
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
        startTransfer(files: info.files, to: device)
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

    func respond(to prompt: PromptItem, accept: Bool) {
        switch prompt {
        case .pairing(let pairing, let decision):
            decision.resolve(accept)
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

    func setWallpaper(_ value: Wallpaper) {
        wallpaper = value
        AppSettings.wallpaper = value.rawValue
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
            self.notify(title: "Incoming files", body: "\(offer.peer.name) wants to send you files.")
        }
    }

    func crossDropOfferFinished(transferId: String) {
        DispatchQueue.main.async {
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
        let entry = HistoryEntry(
            id: snapshot.id, direction: snapshot.direction.rawValue, peerName: snapshot.peerName,
            platform: snapshot.peerPlatform ?? "android", status: snapshot.phase.rawValue,
            files: snapshot.files.map { HistoryFile(name: $0.name, size: $0.size, path: $0.savedURL?.path) },
            totalBytes: snapshot.totalBytes, finishedAt: Date(), errorCode: snapshot.error?.code)
        historyStore.add(entry)
        history = historyStore.entries

        let count = snapshot.files.count
        let noun = count == 1 ? "file" : "\(count) files"
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

    private func notify(title: String, body: String) {
        guard notificationsEnabled, !NSApp.isActive else { return }
        NotificationManager.shared.post(title: title, body: body)
    }
}
