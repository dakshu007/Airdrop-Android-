import Foundation
import CryptoKit

/// Long-term device identity (ECDSA P-256). See protocol §1.1.
public struct DeviceIdentity {
    public let privateKey: P256.Signing.PrivateKey

    public init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// `raw` is the 32-byte big-endian private scalar.
    public init(rawPrivateKey raw: Data) throws {
        self.privateKey = try P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    public static func generate() -> DeviceIdentity {
        DeviceIdentity(privateKey: P256.Signing.PrivateKey())
    }

    public var rawPrivateKey: Data { privateKey.rawRepresentation }
    /// 65-byte X9.63 uncompressed public key.
    public var publicKey: Data { privateKey.publicKey.x963Representation }
    public var fingerprint: String { CDCrypto.fingerprint(of: publicKey) }
    public var deviceId: String { CDCrypto.deviceId(of: publicKey) }

    /// DER-encoded ECDSA-SHA256 signature.
    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data).derRepresentation
    }
}

public enum CDCrypto {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func fingerprint(of identityKey: Data) -> String {
        Hex.encode(sha256(identityKey))
    }

    public static func deviceId(of identityKey: Data) -> String {
        String(fingerprint(of: identityKey).prefix(32))
    }

    public static func transcriptHash(hello: Data, challenge: Data, clientEphPub: Data, clientIdentityKey: Data) -> Data {
        var input = Labels.transcript
        input.append(ByteCodec.lp(hello))
        input.append(ByteCodec.lp(challenge))
        input.append(ByteCodec.lp(clientEphPub))
        input.append(ByteCodec.lp(clientIdentityKey))
        return sha256(input)
    }

    public static func hkdf(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }

    public static func sessionKeys(sharedSecret: Data, transcriptHash: Data) -> (c2s: Data, s2c: Data) {
        (hkdf(ikm: sharedSecret, salt: transcriptHash, info: Labels.c2s, length: 32),
         hkdf(ikm: sharedSecret, salt: transcriptHash, info: Labels.s2c, length: 32))
    }

    /// Six-digit short authentication string (§4.4).
    public static func sas(transcriptHash: Data) -> String {
        var input = Labels.sas
        input.append(transcriptHash)
        let digest = [UInt8](sha256(input))
        let value = (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16) | (UInt32(digest[2]) << 8) | UInt32(digest[3])
        return String(format: "%06u", value % 1_000_000)
    }

    public static func ecdh(privateKey: P256.KeyAgreement.PrivateKey, peerPublicKey: Data) throws -> Data {
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKey)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    public static func verify(signature: Data, over data: Data, publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else {
            return false
        }
        return key.isValidSignature(sig, for: data)
    }

    static func isValidPublicKey(_ data: Data) -> Bool {
        data.count == 65 && (try? P256.KeyAgreement.PublicKey(x963Representation: data)) != nil
    }

    public static func nonce(seq: UInt64) -> Data {
        var out = Data(repeating: 0, count: 4)
        out.append(ByteCodec.u64be(seq))
        return out
    }

    /// Returns ciphertext || tag for kind || body.
    public static func seal(key: SymmetricKey, seq: UInt64, kind: UInt8, body: Data) throws -> Data {
        var plaintext = Data(capacity: body.count + 1)
        plaintext.append(kind)
        plaintext.append(body)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: try AES.GCM.Nonce(data: nonce(seq: seq)))
        var out = box.ciphertext
        out.append(box.tag)
        return out
    }

    public static func seal(key: Data, seq: UInt64, kind: UInt8, body: Data) throws -> Data {
        try seal(key: SymmetricKey(data: key), seq: seq, kind: kind, body: body)
    }

    public static func open(key: SymmetricKey, seq: UInt64, payload: Data) throws -> (kind: UInt8, body: Data) {
        guard payload.count >= 17 else { throw CrossDropError.local(ErrorCode.badFrame, "record too short") }
        let bytes = Data(payload)
        let ciphertext = bytes.prefix(bytes.count - 16)
        let tag = bytes.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonce(seq: seq)), ciphertext: ciphertext, tag: tag)
        let plaintext = try AES.GCM.open(box, using: key)
        guard let kind = plaintext.first else { throw CrossDropError.local(ErrorCode.badFrame, "empty record") }
        return (kind, Data(plaintext.dropFirst()))
    }

    public static func open(key: Data, seq: UInt64, payload: Data) throws -> (kind: UInt8, body: Data) {
        try open(key: SymmetricKey(data: key), seq: seq, payload: payload)
    }
}

/// Incremental SHA-256 for file content.
public struct StreamingHash {
    private var hasher = SHA256()
    public init() {}
    public mutating func update(_ data: Data) { hasher.update(data: data) }
    public func finalizeHex() -> String { Hex.encode(Data(hasher.finalize())) }
}

extension Data {
    var base64: String { base64EncodedString() }
}
