import Foundation
import Security

/// Turbo (§9.10): a multi-file transfer spread over up to `ProtocolConstants.maxTurboStreams`
/// connections. The main connection carries offer / accept / complete; extra connections
/// join with a one-time token and carry whole files, each announced by `transfer.start`.
enum Turbo {
    /// What `transfer.accept` grants: the join token and the total number of connections.
    struct Join {
        let token: String
        let max: Int
    }

    /// 16 random bytes, base64url without padding.
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 22 characters of `[A-Za-z0-9_-]` (16 bytes in base64url without padding).
    static func isValidToken(_ token: String) -> Bool {
        let utf8 = token.utf8
        guard utf8.count == 22 else { return false }
        return utf8.allSatisfy { c in
            (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 45 || c == 95
        }
    }

    /// Parses `join` from `transfer.accept` when the offer asked for `requested` connections.
    /// A sender that did not ask ignores the field.
    static func parseJoin(_ reply: WireMessage, requested: Int?) throws -> Join? {
        guard let raw = reply.fields["join"], !(raw is NSNull) else { return nil }
        guard let requested = requested else { return nil }
        guard let entry = raw as? [String: Any],
              let token = entry["token"] as? String, isValidToken(token),
              let max = JSONValue.int(entry["max"]), max >= 2, max <= Int64(requested) else {
            throw CrossDropError.violation(ErrorCode.badMessage, "bad join")
        }
        return Join(token: token, max: Int(max))
    }
}

/// Receiver side: the transfers that currently accept joins, by transferId.
final class TurboRegistry {
    private let lock = NSLock()
    private var groups: [String: IncomingTurbo] = [:]

    init() {}

    /// False when another transfer already uses this id (that offer then gets no `join`).
    func register(_ group: IncomingTurbo) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if groups[group.transferId] != nil { return false }
        groups[group.transferId] = group
        return true
    }

    func find(_ transferId: String) -> IncomingTurbo? {
        lock.lock()
        defer { lock.unlock() }
        return groups[transferId]
    }

    func remove(_ group: IncomingTurbo) {
        lock.lock()
        if groups[group.transferId] === group { groups[group.transferId] = nil }
        lock.unlock()
    }
}

/// Receiver-side state shared by the connections of one Turbo transfer. Files may arrive
/// on any connection in any order; each is claimed once. The main session sends
/// `transfer.complete` when every file is verified. Any failure ends every connection.
final class IncomingTurbo {
    let transferId: String
    let peer: PeerInfo
    let token: String
    let maxStreams: Int
    let offer: TransferOffer
    let resumeAt: [Int64: Int64]
    let directory: URL
    let publisher: SnapshotPublisher
    let main: SecureChannel
    private let registry: TurboRegistry

    private let lock = NSLock()
    private var sides: [SecureChannel] = []
    private var claimed: Set<Int64> = []
    private var doneCount = 0
    private var failure: CrossDropError?
    private var failureOrigin: SecureChannel?
    private var finished = false
    private var waiter: ContinuationBox<Void>?
    private var lastKeepAlive: TimeInterval = 0

    init(transferId: String, peer: PeerInfo, token: String, maxStreams: Int, offer: TransferOffer,
         resumeAt: [Int64: Int64], directory: URL, publisher: SnapshotPublisher, main: SecureChannel,
         registry: TurboRegistry) {
        self.transferId = transferId
        self.peer = peer
        self.token = token
        self.maxStreams = maxStreams
        self.offer = offer
        self.resumeAt = resumeAt
        self.directory = directory
        self.publisher = publisher
        self.main = main
        self.registry = registry
    }

    /// Completed or failed: no more joins, files or failures.
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var error: CrossDropError? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Connections that took part, the main one included.
    var streams: Int {
        lock.lock()
        defer { lock.unlock() }
        return 1 + sides.count
    }

    /// True when `channel`'s own failure ended the transfer (it then tells the sender itself).
    func isOrigin(_ channel: SecureChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failureOrigin === channel
    }

    /// Adds an extra connection. Returns nil on success, else the error code to refuse it with.
    func join(_ channel: SecureChannel, deviceId: String, token presented: String) -> String? {
        lock.lock()
        if finished || deviceId != peer.deviceId {
            lock.unlock()
            return ErrorCode.unexpectedMessage
        }
        guard Room.constantTimeEqual(Data(presented.utf8), Data(token.utf8)) else {
            lock.unlock()
            return ErrorCode.authFailed
        }
        guard 1 + sides.count < maxStreams else {
            lock.unlock()
            return ErrorCode.busy
        }
        sides.append(channel)
        let count = 1 + sides.count
        lock.unlock()
        publisher.update(force: true) { $0.streams = count }
        keepAlive()
        return nil
    }

    /// Claims `fileId` for the calling connection; returns its index in the offer.
    func claim(_ fileId: Int64) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if finished { throw CrossDropError.local(ErrorCode.connectionLost, "transfer ended") }
        guard let index = offer.files.firstIndex(where: { $0.fileId == fileId }), !claimed.contains(fileId) else {
            throw CrossDropError.violation(ErrorCode.badMessage, "file already sent or unknown")
        }
        claimed.insert(fileId)
        return index
    }

    /// A claimed file was verified and saved; wakes the main session after the last one.
    func fileDone() {
        lock.lock()
        doneCount += 1
        let last = doneCount == offer.files.count
        let waiting = last ? waiter : nil
        if last { waiter = nil }
        lock.unlock()
        waiting?.resume(returning: ())
    }

    /// Returns once every file is verified; throws the transfer's failure.
    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            lock.lock()
            if let failure = failure {
                lock.unlock()
                box.resume(throwing: failure)
                return
            }
            if doneCount == offer.files.count {
                lock.unlock()
                box.resume(returning: ())
                return
            }
            waiter = box
            lock.unlock()
        }
    }

    /// Every file is verified and `transfer.complete` went out. The sender closes the extra
    /// connections once it has read it; any still open after a grace period are closed here.
    func complete() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let open = sides
        lock.unlock()
        registry.remove(self)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.closeGrace) {
            for channel in open { channel.transport.close() }
        }
    }

    /// How long extra connections may stay open after `transfer.complete`.
    static let closeGrace: TimeInterval = 5

    /// Records the first failure and ends every other connection, telling the sender why
    /// when it is our own error. Returns false when the transfer had already finished.
    @discardableResult
    func fail(_ error: CrossDropError, origin: SecureChannel?) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        finished = true
        failure = error
        failureOrigin = origin
        let others = ([main] + sides).filter { $0 !== origin }
        let waiting = waiter
        waiter = nil
        lock.unlock()
        registry.remove(self)
        waiting?.resume(throwing: error)
        var message: [String: Any]? = nil
        if error.fromPeer || error.code == ErrorCode.connectionLost || error.code == ErrorCode.timeout {
            message = nil
        } else if error.isCancellation {
            message = WireMessage.make("transfer.cancel", ["transferId": transferId, "reason": "user"])
        } else if let code = error.peerCode {
            message = WireMessage.error(code)
        }
        for channel in others {
            let note = message
            Task {
                if let note = note, channel.isEncrypted { try? await channel.sendControl(note) }
                channel.transport.close()
            }
        }
        return true
    }

    /// Data moved on one connection: keeps the others' inactivity timers from firing (at most once a second).
    func keepAlive() {
        let now = monotonicNow()
        lock.lock()
        guard now - lastKeepAlive >= 1 else {
            lock.unlock()
            return
        }
        lastKeepAlive = now
        let all = [main] + sides
        lock.unlock()
        for channel in all { channel.transport.keepAlive() }
    }
}

/// Sender-side state of one Turbo transfer: the files still to send and every connection
/// in use. Each connection takes the next file when it is free.
final class OutgoingTurbo {
    let main: SecureChannel
    private let fileCount: Int

    private let lock = NSLock()
    private var nextIndex = 0
    private var sides: [SecureChannel] = []
    private var busy: Set<ObjectIdentifier> = []
    private var joinedCount = 0
    private var failure: CrossDropError?
    private var ended = false
    private var succeeded = false
    private var waiter: ContinuationBox<Void>?
    private var pendingSides: Int
    private var settleWaiter: ContinuationBox<Void>?
    private var lastKeepAlive: TimeInterval = 0

    init(main: SecureChannel, fileCount: Int, sideAttempts: Int) {
        self.main = main
        self.fileCount = fileCount
        self.pendingSides = sideAttempts
    }

    /// Completed or failed.
    var isEnded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ended
    }

    var streams: Int {
        lock.lock()
        defer { lock.unlock() }
        return 1 + joinedCount
    }

    /// The next file for `channel` (which is then busy with it), or nil when none is left.
    func next(for channel: SecureChannel) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !ended, nextIndex < fileCount else { return nil }
        let index = nextIndex
        nextIndex += 1
        busy.insert(ObjectIdentifier(channel))
        return index
    }

    /// `channel` finished its current file.
    func fileSent(on channel: SecureChannel) {
        lock.lock()
        busy.remove(ObjectIdentifier(channel))
        lock.unlock()
    }

    func isBusy(_ channel: SecureChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy.contains(ObjectIdentifier(channel))
    }

    /// False when the transfer already ended (the caller closes `channel`).
    func addSide(_ channel: SecureChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if ended { return false }
        sides.append(channel)
        return true
    }

    func removeSide(_ channel: SecureChannel) {
        lock.lock()
        sides.removeAll { $0 === channel }
        lock.unlock()
    }

    /// An extra connection joined; returns the number of connections now in use.
    func joined() -> Int {
        lock.lock()
        defer { lock.unlock() }
        joinedCount += 1
        return 1 + joinedCount
    }

    /// One extra connection finished trying to join, whatever the outcome.
    func settle() {
        lock.lock()
        if pendingSides > 0 { pendingSides -= 1 }
        let waiting = pendingSides == 0 ? settleWaiter : nil
        if pendingSides == 0 { settleWaiter = nil }
        lock.unlock()
        waiting?.resume(returning: ())
    }

    /// Waits until every extra connection has joined or given up, at most `seconds`.
    func waitSettled(within seconds: TimeInterval) async {
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            lock.lock()
            if pendingSides == 0 || ended {
                lock.unlock()
                box.resume(returning: ())
                return
            }
            settleWaiter = box
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                box.resume(returning: ())
            }
        }
    }

    /// `transfer.complete` arrived on the main connection.
    func succeed() {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        ended = true
        succeeded = true
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: ())
    }

    /// Records the first failure and closes the extra connections. Returns false when the
    /// transfer had already ended.
    @discardableResult
    func fail(_ error: CrossDropError) -> Bool {
        lock.lock()
        if ended {
            lock.unlock()
            return false
        }
        ended = true
        failure = error
        let waiting = waiter
        waiter = nil
        let open = sides
        lock.unlock()
        waiting?.resume(throwing: error)
        for channel in open { channel.transport.close() }
        return true
    }

    /// Throws the recorded failure, if any.
    func checkFailed() throws {
        lock.lock()
        let failure = self.failure
        lock.unlock()
        if let failure = failure { throw failure }
    }

    /// Returns when `transfer.complete` arrived; throws the first failure.
    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            lock.lock()
            if let failure = failure {
                lock.unlock()
                box.resume(throwing: failure)
                return
            }
            if succeeded {
                lock.unlock()
                box.resume(returning: ())
                return
            }
            waiter = box
            lock.unlock()
        }
    }

    /// The sender cancelled: tells the receiver on every extra connection and closes them.
    func cancelSides(transferId: String) {
        lock.lock()
        let open = sides
        lock.unlock()
        for channel in open {
            Task {
                if channel.isEncrypted {
                    try? await channel.sendControl(WireMessage.make("transfer.cancel", [
                        "transferId": transferId, "reason": "user",
                    ]))
                }
                channel.transport.close()
            }
        }
    }

    func closeSides() {
        lock.lock()
        ended = true
        let open = sides
        let waiting = settleWaiter
        settleWaiter = nil
        lock.unlock()
        waiting?.resume(returning: ())
        for channel in open { channel.transport.close() }
    }

    /// Data moved on one connection: keeps the others' inactivity timers from firing (at most once a second).
    func keepAlive() {
        let now = monotonicNow()
        lock.lock()
        guard now - lastKeepAlive >= 1 else {
            lock.unlock()
            return
        }
        lastKeepAlive = now
        let all = [main] + sides
        lock.unlock()
        for channel in all { channel.transport.keepAlive() }
    }
}
