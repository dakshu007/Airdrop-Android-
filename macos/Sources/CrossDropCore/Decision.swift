import Foundation

/// A yes/no question for the local user (pairing or an incoming offer).
/// The UI calls `resolve(_:)`; the engine waits with a timeout and may cancel
/// the question when the peer gives up first.
public final class Decision {
    public enum Outcome: Equatable {
        case accepted
        case declined
        case timedOut
        /// The peer went away or answered first; the prompt should be dismissed.
        case cancelled
    }

    public let id: String
    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiter: CheckedContinuation<Outcome, Never>?

    public init(id: String = UUID().uuidString) {
        self.id = id
    }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome != nil
    }

    /// Pairing only: the user said "This is my device", so its transfers are accepted
    /// without asking from now on (§9.4).
    public var mine: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isMine
    }
    private var isMine = false

    public func resolve(_ accepted: Bool) {
        finish(accepted ? .accepted : .declined)
    }

    /// Pairing answer with the "This is my device" choice.
    public func resolve(_ accepted: Bool, mine: Bool) {
        lock.lock()
        if outcome == nil { isMine = accepted && mine }
        lock.unlock()
        finish(accepted ? .accepted : .declined)
    }

    public func cancel() {
        finish(.cancelled)
    }

    func finish(_ value: Outcome) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = value
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func wait(timeout: TimeInterval) async -> Outcome {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.timedOut)
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            lock.lock()
            if let value = outcome {
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}
