import Foundation

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

/// Trust kept in memory; used by the CLI and tests.
public final class InMemoryTrustStore: TrustProvider {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]
    private var autoAccept: Set<String> = []

    public init() {}

    public func trustedIdentityKey(for deviceId: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return keys[deviceId]
    }

    public func isAutoAccept(deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
        lock.unlock()
    }

    public func touch(peer: PeerInfo) {}

    public func forget(deviceId: String) {
        lock.lock()
        keys[deviceId] = nil
        autoAccept.remove(deviceId)
        lock.unlock()
    }
}
