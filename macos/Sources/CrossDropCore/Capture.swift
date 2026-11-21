import Foundation
import Network

/// What a capture request asks for (§9.7).
public enum CaptureKind: String, Equatable {
    /// Take a new photo with the camera.
    case photo
    /// Pick existing photos or files.
    case pick
}

/// A paired device asked this one to capture something and send it back (§9.7).
/// The answer goes to `replyHost` (the address this request came from) on `replyPort`,
/// or to wherever discovery finds `peer` when the requester gave no port.
public struct CaptureRequest {
    public let requestId: String
    public let kind: CaptureKind
    public let peer: PeerInfo
    public let replyHost: String
    public let replyPort: UInt16?

    public init(requestId: String, kind: CaptureKind, peer: PeerInfo, replyHost: String, replyPort: UInt16?) {
        self.requestId = requestId
        self.kind = kind
        self.peer = peer
        self.replyHost = replyHost
        self.replyPort = replyPort
    }

    /// Where to send the answer, when the requester gave its port.
    public var replyEndpoint: NWEndpoint? {
        guard let port = replyPort, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(replyHost), port: nwPort)
    }
}

/// Capture requests this device sent and still expects an answer to (§9.7). An offer
/// whose `requestId` matches one of these, from the device it was sent to, is accepted
/// without asking, once, within `ProtocolConstants.captureRequestTTL`.
public final class CaptureRequests {
    private struct Entry {
        let deviceId: String
        let expires: Date
    }

    private let lock = NSLock()
    private var pending: [String: Entry] = [:]

    public init() {}

    /// Registers `requestId` as sent to `deviceId`. False for a malformed id.
    @discardableResult
    public func expect(_ requestId: String, deviceId: String,
                       ttl: TimeInterval = ProtocolConstants.captureRequestTTL) -> Bool {
        guard TransferOffer.isValidTransferId(requestId) else { return false }
        let now = Date()
        lock.lock()
        pending = pending.filter { $0.value.expires >= now }
        pending[requestId] = Entry(deviceId: deviceId, expires: now.addingTimeInterval(ttl))
        lock.unlock()
        return true
    }

    /// Uses up `requestId` if it is outstanding for `deviceId`. A different device never consumes it.
    public func redeem(_ requestId: String, deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = pending[requestId], entry.deviceId == deviceId else { return false }
        pending[requestId] = nil
        return entry.expires >= Date()
    }

    public func cancel(_ requestId: String) {
        lock.lock()
        pending[requestId] = nil
        lock.unlock()
    }

    public func cancelAll() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    public var outstanding: Int {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        return pending.values.filter { $0.expires >= now }.count
    }
}

/// Requester side of §9.7: asks a paired device to take a photo (or pick files) and send it back.
public enum CaptureClient {
    /// Connects, sends `capture.request` and returns its requestId once the other device
    /// accepted. Throws `CrossDropError` with code `declined` when it declined.
    /// `replyPort` is this device's listening port; `registry` (usually the local server's
    /// `captureRequests`) learns the requestId before it is sent, so the answer is accepted
    /// without a prompt. The other device must already be paired; with `pairingDelegate`
    /// set, an unpaired one is paired first (normal code comparison).
    public static func request(endpoint: NWEndpoint, expectedDeviceId: String? = nil,
                               identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider,
                               kind: CaptureKind, replyPort: UInt16?,
                               registry: CaptureRequests? = nil,
                               pairingDelegate: CrossDropDelegate? = nil) async throws -> String {
        let transport = NWTransport.connect(to: endpoint)
        let channel = SecureChannel(transport: transport)
        do {
            try await transport.start(timeout: ProtocolConstants.connectTimeout)
        } catch {
            transport.close()
            throw CrossDropError.local(ErrorCode.unreachable, "connect failed")
        }
        var requestId: String? = nil
        do {
            let handshake = try await Handshake.runClient(channel: channel, identity: identity, local: local, trust: trust)
            let peer = handshake.peer
            if let expected = expectedDeviceId, peer.deviceId != expected {
                throw CrossDropError.local(ErrorCode.peerChangedIdentity, "unexpected device")
            }
            if trust.trustedIdentityKey(for: peer.deviceId) != peer.identityKey {
                guard let delegate = pairingDelegate else {
                    throw CrossDropError.local(ErrorCode.pairingRequired, "not paired")
                }
                try await QrPairingClient.pair(channel: channel, peer: peer, sas: handshake.sas, qr: nil, trust: trust,
                                               delegate: delegate, onDecision: nil)
            }
            let id = UUID().uuidString
            requestId = id
            registry?.expect(id, deviceId: peer.deviceId)
            var fields: [String: Any] = ["requestId": id, "kind": kind.rawValue]
            if let port = replyPort { fields["port"] = Int(port) }
            try await channel.sendControl(WireMessage.make("capture.request", fields))
            // The other app may ask its user first, so allow a human's time.
            let reply = try await channel.receiveControl(timeout: ProtocolConstants.humanTimeout + 5)
            switch reply.type {
            case "capture.ack":
                guard try reply.requireString("requestId", maxBytes: 64) == id else {
                    throw CrossDropError.violation(ErrorCode.badMessage, "wrong requestId")
                }
                guard try reply.requireBool("accepted") else {
                    throw CrossDropError.peer(ErrorCode.declined)
                }
                transport.close()
                return id
            case "error":
                throw reply.peerError()
            case "transfer.cancel":
                throw CrossDropError.peer(ErrorCode.cancelled)
            default:
                throw CrossDropError.violation(ErrorCode.unexpectedMessage)
            }
        } catch let error as CrossDropError {
            if let id = requestId { registry?.cancel(id) }
            await channel.abort(with: error)
            throw error
        } catch {
            if let id = requestId { registry?.cancel(id) }
            transport.close()
            throw error
        }
    }
}
