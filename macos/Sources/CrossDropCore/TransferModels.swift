import Foundation

public enum TransferDirection: String, Codable {
    case outgoing
    case incoming
}

public enum TransferPhase: String, Codable {
    case preparing
    case connecting
    case pairing
    case waitingForAcceptance
    case awaitingApproval
    case transferring
    case completed
    case failed
    case cancelled
    case rejected

    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled, .rejected: return true
        default: return false
        }
    }
}

public struct TransferFileState: Equatable {
    public var name: String
    public var size: Int64
    public var mime: String?
    /// Bytes moved for this file on this device.
    public var bytes: Int64
    public var sha256: String?
    /// Outgoing: where the file is read from.
    public var sourceURL: URL?
    /// Incoming: where the verified file was saved.
    public var savedURL: URL?

    public init(name: String, size: Int64, mime: String?, bytes: Int64 = 0, sha256: String? = nil,
                sourceURL: URL? = nil, savedURL: URL? = nil) {
        self.name = name
        self.size = size
        self.mime = mime
        self.bytes = bytes
        self.sha256 = sha256
        self.sourceURL = sourceURL
        self.savedURL = savedURL
    }
}

public struct TransferSnapshot: Equatable {
    public var id: String
    public var direction: TransferDirection
    public var peerId: String?
    public var peerName: String
    public var peerPlatform: String?
    public var phase: TransferPhase
    public var files: [TransferFileState]
    public var startedAt: Date
    public var updatedAt: Date
    public var error: CrossDropError?
    /// Reason from transfer.reject (or the local decision on the receiver).
    public var rejectReason: String?
    /// Outgoing only: bytes the receiver reported via transfer.progress.
    public var peerConfirmedBytes: Int64
    /// Files, or a link / text that is not saved (§9.2).
    public var kind: OfferKind
    /// Incoming link / text, set when it has arrived and was verified.
    public var text: String?
    /// Bytes skipped because the receiver kept them from an interrupted attempt (§9.3).
    public var resumedBytes: Int64
    /// The capture request this transfer answers (§9.7). Incoming: set only when it matched
    /// a request this device sent to the same peer (and so was accepted without asking).
    public var requestId: String?
    /// Seconds after which the sender asks that the received items be deleted (§9.8).
    /// The receiving app does the deleting; the core only reports it.
    public var expiresAfter: Int64?
    /// Connections this transfer uses, the main one included: more than 1 with Turbo (§9.10).
    public var streams: Int

    public init(id: String, direction: TransferDirection, peerId: String?, peerName: String,
                peerPlatform: String?, phase: TransferPhase, files: [TransferFileState]) {
        self.id = id
        self.direction = direction
        self.peerId = peerId
        self.peerName = peerName
        self.peerPlatform = peerPlatform
        self.phase = phase
        self.files = files
        self.startedAt = Date()
        self.updatedAt = Date()
        self.error = nil
        self.rejectReason = nil
        self.peerConfirmedBytes = 0
        self.kind = .files
        self.text = nil
        self.resumedBytes = 0
        self.requestId = nil
        self.expiresAfter = nil
        self.streams = 1
    }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var bytesTransferred: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

public struct PairingPrompt {
    public enum Role: String {
        /// This device opened the connection.
        case sender
        case receiver
    }

    public let id: String
    public let peer: PeerInfo
    /// Six digits.
    public let code: String
    public let role: Role
    public let expiresAt: Date
}

public struct OfferPrompt {
    public let transferId: String
    public let peer: PeerInfo
    public let files: [OfferedFile]
    public let totalBytes: Int64
    public let expiresAt: Date
    public var kind: OfferKind = .files
    /// Seconds after which the sender asks that the received items be deleted (§9.8).
    public var expiresAfter: Int64? = nil
}

/// Callbacks from the engine. Called on background threads.
public protocol CrossDropDelegate: AnyObject {
    /// Ask the user to compare `prompt.code` with the other screen, then call `decision.resolve`.
    func crossDropPairingRequested(_ prompt: PairingPrompt, decision: Decision)
    /// The pairing prompt can be dismissed (both confirmed, declined, timed out or the peer left).
    func crossDropPairingFinished(id: String, success: Bool)
    func crossDropOfferReceived(_ offer: OfferPrompt, decision: Decision)
    func crossDropOfferFinished(transferId: String)
    func crossDropTransferUpdated(_ snapshot: TransferSnapshot)
    /// A paired device asks this one to take a photo or pick files and send them back (§9.7).
    /// Return true to accept; the app then sends the result to `request.replyEndpoint` with
    /// `OutgoingTransfer(requestId: request.requestId)`. The requester waits up to the human timeout.
    func crossDropCaptureRequested(_ request: CaptureRequest) -> Bool
}

public extension CrossDropDelegate {
    func crossDropCaptureRequested(_ request: CaptureRequest) -> Bool { false }
}

/// Thread-safe holder that throttles progress notifications.
final class SnapshotPublisher {
    private let lock = NSLock()
    private var snapshot: TransferSnapshot
    private var lastPublish: TimeInterval = 0
    private weak var delegate: CrossDropDelegate?

    init(_ snapshot: TransferSnapshot, delegate: CrossDropDelegate?) {
        self.snapshot = snapshot
        self.delegate = delegate
    }

    var current: TransferSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Applies `change`. Phase changes publish immediately; byte counts at most 10×/s.
    func update(force: Bool = false, _ change: (inout TransferSnapshot) -> Void) {
        lock.lock()
        let oldPhase = snapshot.phase
        change(&snapshot)
        snapshot.updatedAt = Date()
        let now = monotonicNow()
        let publish = force || snapshot.phase != oldPhase || now - lastPublish >= 0.1
        if publish { lastPublish = now }
        let copy = snapshot
        lock.unlock()
        if publish { delegate?.crossDropTransferUpdated(copy) }
    }

    func finish(_ phase: TransferPhase, error: CrossDropError? = nil, rejectReason: String? = nil) {
        update(force: true) { s in
            guard !s.phase.isFinished else { return }
            s.phase = phase
            s.error = error
            if let reason = rejectReason { s.rejectReason = reason }
        }
    }
}
