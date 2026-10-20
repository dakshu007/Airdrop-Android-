import Foundation
import CryptoKit

/// Framing on top of a transport: plaintext JSON frames during the handshake,
/// AES-256-GCM records afterwards (docs/protocol-v1.md §3).
public final class SecureChannel {
    public enum Record {
        case control(WireMessage)
        case data(Data)
    }

    public let transport: NWTransport
    private let lock = NSLock()
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendSeq: UInt64 = 0
    // Only the single reader touches receiveSeq.
    private var receiveSeq: UInt64 = 0

    public init(transport: NWTransport) {
        self.transport = transport
    }

    public var isEncrypted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sendKey != nil
    }

    func activate(sendKey: Data, receiveKey: Data) {
        lock.lock()
        self.sendKey = SymmetricKey(data: sendKey)
        self.receiveKey = SymmetricKey(data: receiveKey)
        sendSeq = 0
        receiveSeq = 0
        lock.unlock()
    }

    /// Validates a length prefix for the current phase (§3.1, §3.2).
    static func validateLength(_ length: Int, encrypted: Bool) throws {
        guard length > 0 else { throw CrossDropError.violation(ErrorCode.badFrame, "zero length") }
        let maximum = encrypted ? ProtocolConstants.maxEncryptedPayload : ProtocolConstants.maxPlaintextPayload
        guard length <= maximum else { throw CrossDropError.violation(ErrorCode.frameTooLarge) }
    }

    // MARK: Plaintext phase

    func sendPlaintext(_ json: Data) async throws {
        guard !json.isEmpty, json.count <= ProtocolConstants.maxPlaintextPayload else {
            throw CrossDropError.local(ErrorCode.internalError, "plaintext frame size")
        }
        var frame = ByteCodec.u32be(UInt32(json.count))
        frame.append(json)
        try await transport.send(frame)
    }

    func receivePlaintext(timeout: TimeInterval) async throws -> Data {
        let header = try await transport.receive(exactly: 4, timeout: timeout)
        let length = Int(ByteCodec.readU32be(header))
        try Self.validateLength(length, encrypted: false)
        return try await transport.receive(exactly: length, timeout: timeout)
    }

    // MARK: Encrypted phase

    func sendRecord(kind: UInt8, body: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ContinuationBox(continuation)
            lock.lock()
            defer { lock.unlock() }
            guard let key = sendKey else {
                box.resume(throwing: CrossDropError.local(ErrorCode.internalError, "channel not encrypted"))
                return
            }
            do {
                let payload = try CDCrypto.seal(key: key, seq: sendSeq, kind: kind, body: body)
                sendSeq += 1
                var frame = ByteCodec.u32be(UInt32(payload.count))
                frame.append(payload)
                // Called under the lock so records hit the wire in seq order.
                transport.enqueueSend(frame, box: box)
            } catch {
                box.resume(throwing: CrossDropError.local(ErrorCode.internalError, "seal failed"))
            }
        }
    }

    /// Sends a control message, plaintext or encrypted depending on the phase.
    public func sendControl(_ message: [String: Any]) async throws {
        let json = try WireMessage.encode(message)
        if isEncrypted {
            guard json.count <= ProtocolConstants.maxPlaintextPayload else {
                throw CrossDropError.local(ErrorCode.internalError, "control message too large")
            }
            try await sendRecord(kind: ProtocolConstants.recordKindControl, body: json)
        } else {
            try await sendPlaintext(json)
        }
    }

    public func sendData(_ body: Data) async throws {
        try await sendRecord(kind: ProtocolConstants.recordKindData, body: body)
    }

    public func receiveRecord(timeout: TimeInterval) async throws -> Record {
        guard let key = currentReceiveKey() else {
            let raw = try await receivePlaintext(timeout: timeout)
            return .control(try WireMessage.parse(raw))
        }
        let header = try await transport.receive(exactly: 4, timeout: timeout)
        let length = Int(ByteCodec.readU32be(header))
        try Self.validateLength(length, encrypted: true)
        let payload = try await transport.receive(exactly: length, timeout: timeout)
        let opened: (kind: UInt8, body: Data)
        do {
            opened = try CDCrypto.open(key: key, seq: receiveSeq, payload: payload)
        } catch {
            // Fatal and silent (§3.2).
            transport.close()
            throw CrossDropError.local(ErrorCode.badFrame, "record authentication failed")
        }
        receiveSeq += 1
        switch opened.kind {
        case ProtocolConstants.recordKindControl:
            guard opened.body.count <= ProtocolConstants.maxPlaintextPayload else {
                throw CrossDropError.violation(ErrorCode.frameTooLarge)
            }
            return .control(try WireMessage.parse(opened.body))
        case ProtocolConstants.recordKindData:
            guard !opened.body.isEmpty, opened.body.count <= ProtocolConstants.maxDataBody else {
                throw CrossDropError.violation(ErrorCode.badFrame, "data record size")
            }
            return .data(opened.body)
        default:
            throw CrossDropError.violation(ErrorCode.badFrame, "unknown record kind")
        }
    }

    /// Next control message; a data record here is a protocol violation.
    public func receiveControl(timeout: TimeInterval) async throws -> WireMessage {
        switch try await receiveRecord(timeout: timeout) {
        case .control(let message):
            return message
        case .data:
            throw CrossDropError.violation(ErrorCode.badMessage, "data outside a file")
        }
    }

    /// Best effort: tell the peer about `error` if appropriate, then close.
    func abort(with error: CrossDropError) async {
        if let code = error.peerCode, !transport.isClosed {
            try? await sendControl(WireMessage.error(code))
        }
        transport.close()
    }

    private func currentReceiveKey() -> SymmetricKey? {
        lock.lock()
        defer { lock.unlock() }
        return receiveKey
    }
}
