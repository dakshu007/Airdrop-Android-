import Foundation
import Security

/// Loads or creates an identity stored as 64 hex chars in a file (CLI and tests only;
/// the app keeps its key in the Keychain).
public enum FileIdentityStore {
    public static func loadOrCreate(at url: URL) throws -> DeviceIdentity {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw = Hex.decode(trimmed), raw.count == 32 else {
                throw CrossDropError.local(ErrorCode.internalError, "identity file is not 64 hex characters")
            }
            return try DeviceIdentity(rawPrivateKey: raw)
        }
        let identity = DeviceIdentity.generate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(Hex.encode(identity.rawPrivateKey).utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CrossDropError.local(ErrorCode.internalError, "cannot write identity file")
        }
        return identity
    }
}

/// Trust kept in memory; used by the CLI and tests. Honours trust expiry (§9.9).
public final class InMemoryTrustStore: TrustProvider {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private var autoAccept: Set<String> = []
    private var expiry: [String: Date] = [:]

    public init() {}

    /// Drops `deviceId` if its temporary trust has ended. Call with the lock held.
    private func purgeIfExpired(_ deviceId: String) {
        if let end = expiry[deviceId], Date() >= end {
            keys[deviceId] = nil
            autoAccept.remove(deviceId)
            expiry[deviceId] = nil
        }
    }

    public func trustedIdentityKey(for deviceId: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        purgeIfExpired(deviceId)
        return keys[deviceId]
    }

    public func isAutoAccept(deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purgeIfExpired(deviceId)
        return autoAccept.contains(deviceId)
    }

    public func setAutoAccept(_ value: Bool, deviceId: String) {
        lock.lock()
        if value { autoAccept.insert(deviceId) } else { autoAccept.remove(deviceId) }
        lock.unlock()
    }

    public func storeTrust(for peer: PeerInfo) {
        lock.lock()
        keys[peer.deviceId] = peer.identityKey
        expiry[peer.deviceId] = nil
        lock.unlock()
    }

    public func storeTrust(for peer: PeerInfo, autoAccept value: Bool) {
        storeTrust(for: peer, autoAccept: value, expiresAt: nil)
    }

    public func storeTrust(for peer: PeerInfo, autoAccept value: Bool, expiresAt: Date?) {
        lock.lock()
        keys[peer.deviceId] = peer.identityKey
        if value { autoAccept.insert(peer.deviceId) }
        expiry[peer.deviceId] = expiresAt
        lock.unlock()
    }

    public var supportsTrustExpiry: Bool { true }

    public func trustExpiry(for deviceId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        purgeIfExpired(deviceId)
        return expiry[deviceId]
    }

    public func touch(peer: PeerInfo) {}

    public func forget(deviceId: String) {
        lock.lock()
        keys[deviceId] = nil
        autoAccept.remove(deviceId)
        expiry[deviceId] = nil
        lock.unlock()
    }
}

/// One-time tokens a receiver shows inside a pairing QR code (§9.4). Scanning the
/// code proves the scanner can see this screen, so a pairing request that presents
/// a valid token skips the code comparison on this side.
public final class PairingTokens {
    private struct Entry {
        let expires: Date
        let mine: Bool
    }

    private let lock = NSLock()
    private var tokens: [String: Entry] = [:]

    public init() {}

    /// A fresh token, valid for `ProtocolConstants.pairingTokenTTL`; `mine` is the
    /// local "This is my device" choice.
    public func issue(mine: Bool) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let now = Date()
        lock.lock()
        tokens = tokens.filter { $0.value.expires > now }
        tokens[token] = Entry(expires: now.addingTimeInterval(ProtocolConstants.pairingTokenTTL), mine: mine)
        lock.unlock()
        return token
    }

    /// Uses up `token`. Returns the "mine" choice it was issued with, or nil if it is not valid.
    public func redeem(_ token: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = tokens.removeValue(forKey: token), entry.expires > Date() else { return nil }
        return entry.mine
    }

    public func revokeAll() {
        lock.lock()
        tokens.removeAll()
        lock.unlock()
    }
}

/// What a scanned pairing QR code says about the receiver (§9.4).
public struct QrPairing: Equatable {
    public let token: String
    /// SHA-256 of the receiver's identity key, lowercase hex.
    public let fingerprint: String
    /// This side's "This is my device" choice.
    public let mine: Bool

    public init(token: String, fingerprint: String, mine: Bool) {
        self.token = token
        self.fingerprint = fingerprint
        self.mine = mine
    }
}
