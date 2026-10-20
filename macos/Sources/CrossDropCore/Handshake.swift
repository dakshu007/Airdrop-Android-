import Foundation
import CryptoKit

/// The other side of a connection, after its identity key was verified.
public struct PeerInfo: Equatable {
    public let deviceId: String
    public let name: String
    public let platform: String
    public let appVersion: String?
    public let identityKey: Data

    public init(deviceId: String, name: String, platform: String, appVersion: String?, identityKey: Data) {
        self.deviceId = deviceId
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
        self.identityKey = identityKey
    }

    public var fingerprint: String { CDCrypto.fingerprint(of: identityKey) }
}

/// What this device tells peers about itself.
public struct LocalInfo {
    public var name: String
    public var platform: String
    public var appVersion: String

    public init(name: String, platform: String = "macos", appVersion: String) {
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
    }

    /// Name as sent on the wire: trimmed, at most 64 scalars, never empty.
    var wireName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: trimmed.unicodeScalars.prefix(64))
        let result = String(view)
        return result.isEmpty ? "Mac" : result
    }
}

/// Trust decisions the engine needs. Implementations must be thread-safe.
public protocol TrustProvider: AnyObject {
    /// Stored identity key for a trusted device, nil when not trusted.
    func trustedIdentityKey(for deviceId: String) -> Data?
    func isAutoAccept(deviceId: String) -> Bool
    /// Called after both users confirmed pairing.
    func storeTrust(for peer: PeerInfo)
    /// Called after a successful transfer with an already-trusted peer.
    func touch(peer: PeerInfo)
}

struct HandshakeResult {
    let peer: PeerInfo
    let sas: String
}

/// docs/protocol-v1.md §4.
enum Handshake {
    static func runClient(channel: SecureChannel, identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider) async throws -> HandshakeResult {
        let timeout = ProtocolConstants.handshakeTimeout
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephPub = ephemeral.publicKey.x963Representation

        let hello = try WireMessage.encode(WireMessage.make("hello", [
            "minV": 1,
            "deviceId": identity.deviceId,
            "name": local.wireName,
            "platform": local.platform,
            "appVersion": local.appVersion,
            "ephCommit": CDCrypto.sha256(ephPub).base64,
        ]))
        try await channel.sendPlaintext(hello)

        let challengeBytes = try await channel.receivePlaintext(timeout: timeout)
        let challenge = try WireMessage.parse(challengeBytes)
        if challenge.type == "error" { throw challenge.peerError() }
        guard challenge.type == "auth.challenge" else {
            throw CrossDropError.violation(ErrorCode.unexpectedMessage)
        }
        guard challenge.version == 1 else { throw CrossDropError.violation(ErrorCode.unsupportedVersion) }
        let peerId = try challenge.requireDeviceId()
        let peerName = try challenge.requireName()
        let peerPlatform = try challenge.requirePlatform()
        let peerVersion = challenge.string("appVersion").map { String($0.prefix(32)) }
        let serverEph = try challenge.requireBase64("ephPub", length: 65)
        let serverIdentity = try challenge.requireBase64("identityKey", length: 65)
        guard CDCrypto.isValidPublicKey(serverIdentity), CDCrypto.isValidPublicKey(serverEph),
              CDCrypto.deviceId(of: serverIdentity) == peerId else {
            throw CrossDropError.violation(ErrorCode.authFailed, "identity mismatch")
        }
        if let known = trust.trustedIdentityKey(for: peerId), known != serverIdentity {
            throw CrossDropError(ErrorCode.peerChangedIdentity, "stored key differs", peerCode: ErrorCode.authFailed)
        }

        let th = CDCrypto.transcriptHash(hello: hello, challenge: challengeBytes,
                                         clientEphPub: ephPub, clientIdentityKey: identity.publicKey)
        let signature = try identity.sign(Labels.clientProof + th)
        try await channel.sendPlaintext(try WireMessage.encode(WireMessage.make("auth.proof", [
            "ephPub": ephPub.base64,
            "identityKey": identity.publicKey.base64,
            "signature": signature.base64,
        ])))

        let proof = try WireMessage.parse(try await channel.receivePlaintext(timeout: timeout))
        if proof.type == "error" { throw proof.peerError() }
        guard proof.type == "auth.proof" else { throw CrossDropError.violation(ErrorCode.unexpectedMessage) }
        let serverSignature = try proof.requireBase64("signature", maxLength: 256)
        guard CDCrypto.verify(signature: serverSignature, over: Labels.serverProof + th, publicKey: serverIdentity) else {
            throw CrossDropError.violation(ErrorCode.authFailed, "server signature")
        }

        let shared: Data
        do {
            shared = try CDCrypto.ecdh(privateKey: ephemeral, peerPublicKey: serverEph)
        } catch {
            throw CrossDropError.violation(ErrorCode.authFailed, "key agreement")
        }
        let keys = CDCrypto.sessionKeys(sharedSecret: shared, transcriptHash: th)
        channel.activate(sendKey: keys.c2s, receiveKey: keys.s2c)

        let peer = PeerInfo(deviceId: peerId, name: peerName, platform: peerPlatform,
                            appVersion: peerVersion, identityKey: serverIdentity)
        return HandshakeResult(peer: peer, sas: CDCrypto.sas(transcriptHash: th))
    }

    static func runServer(channel: SecureChannel, identity: DeviceIdentity, local: LocalInfo, trust: TrustProvider) async throws -> HandshakeResult {
        let timeout = ProtocolConstants.handshakeTimeout

        let helloBytes = try await channel.receivePlaintext(timeout: timeout)
        let hello = try WireMessage.parse(helloBytes)
        if hello.type == "error" { throw hello.peerError() }
        guard hello.type == "hello" else { throw CrossDropError.violation(ErrorCode.unexpectedMessage) }
        let maxVersion = hello.version
        let minVersion = hello.int("minV") ?? maxVersion
        guard minVersion <= 1, maxVersion >= 1 else {
            throw CrossDropError.violation(ErrorCode.unsupportedVersion)
        }
        let peerId = try hello.requireDeviceId()
        let peerName = try hello.requireName()
        let peerPlatform = try hello.requirePlatform()
        let peerVersion = hello.string("appVersion").map { String($0.prefix(32)) }
        let commit = try hello.requireBase64("ephCommit", length: 32)

        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephPub = ephemeral.publicKey.x963Representation
        let challenge = try WireMessage.encode(WireMessage.make("auth.challenge", [
            "deviceId": identity.deviceId,
            "name": local.wireName,
            "platform": local.platform,
            "appVersion": local.appVersion,
            "ephPub": ephPub.base64,
            "identityKey": identity.publicKey.base64,
        ]))
        try await channel.sendPlaintext(challenge)

        let proof = try WireMessage.parse(try await channel.receivePlaintext(timeout: timeout))
        if proof.type == "error" { throw proof.peerError() }
        guard proof.type == "auth.proof" else { throw CrossDropError.violation(ErrorCode.unexpectedMessage) }
        let clientEph = try proof.requireBase64("ephPub", length: 65)
        let clientIdentity = try proof.requireBase64("identityKey", length: 65)
        let clientSignature = try proof.requireBase64("signature", maxLength: 256)

        let authFailed = CrossDropError.violation(ErrorCode.authFailed)
        guard CDCrypto.sha256(clientEph) == commit else { throw authFailed }
        guard CDCrypto.isValidPublicKey(clientIdentity), CDCrypto.isValidPublicKey(clientEph),
              CDCrypto.deviceId(of: clientIdentity) == peerId else { throw authFailed }
        if let known = trust.trustedIdentityKey(for: peerId), known != clientIdentity { throw authFailed }
        let th = CDCrypto.transcriptHash(hello: helloBytes, challenge: challenge,
                                         clientEphPub: clientEph, clientIdentityKey: clientIdentity)
        guard CDCrypto.verify(signature: clientSignature, over: Labels.clientProof + th, publicKey: clientIdentity) else {
            throw authFailed
        }
        let shared: Data
        do {
            shared = try CDCrypto.ecdh(privateKey: ephemeral, peerPublicKey: clientEph)
        } catch {
            throw authFailed
        }

        let signature = try identity.sign(Labels.serverProof + th)
        try await channel.sendPlaintext(try WireMessage.encode(WireMessage.make("auth.proof", [
            "signature": signature.base64,
        ])))
        let keys = CDCrypto.sessionKeys(sharedSecret: shared, transcriptHash: th)
        channel.activate(sendKey: keys.s2c, receiveKey: keys.c2s)

        let peer = PeerInfo(deviceId: peerId, name: peerName, platform: peerPlatform,
                            appVersion: peerVersion, identityKey: clientIdentity)
        return HandshakeResult(peer: peer, sas: CDCrypto.sas(transcriptHash: th))
    }
}
