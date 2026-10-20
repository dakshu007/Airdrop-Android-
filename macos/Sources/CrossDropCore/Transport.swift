import Foundation
import Network

/// Resumes a checked continuation at most once, from any thread.
final class ContinuationBox<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }
}

/// async/await wrapper around one NWConnection (TCP).
///
/// Reads are inactivity-based: a pending read fails with `timeout` once neither
/// a byte was received nor a send completed for `timeout` seconds. That lets a
/// sender wait for control messages while it is busy streaming.
public final class NWTransport {
    public let connection: NWConnection
    let queue: DispatchQueue

    private let lock = NSLock()
    private var pendingReceive: ContinuationBox<Data>?
    private var pendingSends: [UInt64: ContinuationBox<Void>] = [:]
    private var nextSendId: UInt64 = 0
    private var lastActivity: TimeInterval = monotonicNow()
    private var closedError: CrossDropError?
    private var started = false

    public init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "app.crossdrop.connection")
    }

    public static func connect(to endpoint: NWEndpoint) -> NWTransport {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = Int(ProtocolConstants.connectTimeout)
        }
        return NWTransport(connection: NWConnection(to: endpoint, using: parameters))
    }

    /// Starts the connection and waits until it is ready.
    public func start(timeout: TimeInterval = ProtocolConstants.connectTimeout) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            lock.lock()
            started = true
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    box.resume(returning: ())
                case .failed(let error):
                    box.resume(throwing: CrossDropError.local(ErrorCode.unreachable, "\(error)"))
                    self?.fail(with: CrossDropError.local(ErrorCode.connectionLost, "connection failed"))
                case .cancelled:
                    box.resume(throwing: CrossDropError.local(ErrorCode.unreachable, "cancelled"))
                    self?.fail(with: CrossDropError.local(ErrorCode.connectionLost, "connection closed"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                if case .ready = self.connection.state { return }
                box.resume(throwing: CrossDropError.local(ErrorCode.unreachable, "connect timeout"))
                self.fail(with: CrossDropError.local(ErrorCode.unreachable, "connect timeout"))
            }
        }
    }

    /// Reads exactly `count` bytes.
    public func receive(exactly count: Int, timeout: TimeInterval) async throws -> Data {
        if count <= 0 { return Data() }
        var buffer = Data()
        buffer.reserveCapacity(count)
        touch()
        let watchdog = makeWatchdog(timeout: timeout)
        defer { watchdog.cancel() }
        while buffer.count < count {
            let chunk = try await receiveChunk(maximum: count - buffer.count)
            buffer.append(chunk)
            if !chunk.isEmpty { touch() }
        }
        return buffer
    }

    private func receiveChunk(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let box = ContinuationBox(continuation)
            lock.lock()
            if let error = closedError {
                lock.unlock()
                box.resume(throwing: error)
                return
            }
            pendingReceive = box
            lock.unlock()
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { [weak self] data, _, isComplete, error in
                self?.clearPendingReceive(box)
                if let data = data, !data.isEmpty {
                    box.resume(returning: data)
                } else if error != nil {
                    box.resume(throwing: self?.currentError() ?? CrossDropError.local(ErrorCode.connectionLost))
                } else if isComplete {
                    box.resume(throwing: CrossDropError.local(ErrorCode.connectionLost, "closed by peer"))
                } else {
                    box.resume(returning: Data())
                }
            }
        }
    }

    /// Sends and waits until the stack has taken the bytes (backpressure).
    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueueSend(data, box: ContinuationBox(continuation))
        }
    }

    /// Hands `data` to the connection immediately; `box` resumes on completion.
    /// Synchronous so callers can preserve ordering under their own lock.
    func enqueueSend(_ data: Data, box: ContinuationBox<Void>) {
        lock.lock()
        if let error = closedError {
            lock.unlock()
            box.resume(throwing: error)
            return
        }
        let id = nextSendId
        nextSendId += 1
        pendingSends[id] = box
        lock.unlock()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self = self else {
                box.resume(throwing: CrossDropError.local(ErrorCode.connectionLost))
                return
            }
            self.lock.lock()
            self.pendingSends[id] = nil
            self.lastActivity = monotonicNow()
            self.lock.unlock()
            if error != nil {
                box.resume(throwing: self.currentError() ?? CrossDropError.local(ErrorCode.connectionLost))
            } else {
                box.resume(returning: ())
            }
        })
    }

    /// Closes the connection gracefully; pending operations fail.
    public func close() {
        fail(with: CrossDropError.local(ErrorCode.connectionLost, "closed"))
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedError != nil
    }

    func fail(with error: CrossDropError) {
        lock.lock()
        if closedError == nil { closedError = error }
        let receive = pendingReceive
        pendingReceive = nil
        let sends = Array(pendingSends.values)
        pendingSends.removeAll()
        let reported = closedError ?? error
        lock.unlock()
        receive?.resume(throwing: reported)
        for box in sends { box.resume(throwing: reported) }
        connection.cancel()
    }

    private func currentError() -> CrossDropError? {
        lock.lock()
        defer { lock.unlock() }
        return closedError
    }

    private func clearPendingReceive(_ box: ContinuationBox<Data>) {
        lock.lock()
        if pendingReceive === box { pendingReceive = nil }
        lock.unlock()
    }

    private func touch() {
        lock.lock()
        lastActivity = monotonicNow()
        lock.unlock()
    }

    private func makeWatchdog(timeout: TimeInterval) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let idle = monotonicNow() - self.lastActivity
            self.lock.unlock()
            if idle > timeout {
                self.fail(with: CrossDropError.local(ErrorCode.timeout))
            }
        }
        timer.resume()
        return timer
    }
}
