import Foundation
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct TrustedDeviceRecord: Codable, Identifiable, Equatable {
    var id: String { deviceId }
    let deviceId: String
    var identityKey: Data
    var name: String
    var platform: String
    var pairedAt: Date
    var lastUsedAt: Date?
    var autoAccept: Bool
    /// Last IPv4 address and port that worked, for networks that block discovery (§9.5).
    var lastHost: String?
    var lastPort: UInt16?
    /// Temporary trust from a Drip Room (§9.9) ends here; nil = permanent pairing.
    /// Optional so files written by older versions still load.
    var expiresAt: Date? = nil

    var fingerprint: String { CDCrypto.fingerprint(of: identityKey) }

    /// Trust from a Drip Room that ends by itself.
    var isTemporary: Bool { expiresAt != nil }

    func isExpired(now: Date = Date()) -> Bool {
        guard let end = expiresAt else { return false }
        return now >= end
    }
}

/// Paired devices, persisted as JSON in Application Support. The file holds
/// public keys only. Thread-safe: the engine calls it from background threads.
///
/// Honours trust expiry (§9.9): Drip Room members are stored with `expiresAt`; once
/// that has passed they count as untrusted everywhere and are purged from the file.
final class TrustStore: TrustProvider {
    private let lock = NSLock()
    private var records: [String: TrustedDeviceRecord] = [:]
    private let url = AppPaths.supportDirectory.appendingPathComponent("trusted-devices.json")
    /// Called on an arbitrary thread after every change.
    var onChange: (([TrustedDeviceRecord]) -> Void)?

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? Self.decoder.decode([TrustedDeviceRecord].self, from: data) {
            let now = Date()
            for record in list where CDCrypto.deviceId(of: record.identityKey) == record.deviceId && !record.isExpired(now: now) {
                records[record.deviceId] = record
            }
        }
    }

    /// Trusted devices, expired room trust left out, most recently used first.
    var all: [TrustedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return records.values.filter { !$0.isExpired(now: now) }
            .sorted { ($0.lastUsedAt ?? $0.pairedAt) > ($1.lastUsedAt ?? $1.pairedAt) }
    }

    /// The earliest moment a temporary trust ends, for scheduling a purge.
    var nextExpiry: Date? {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return records.values.compactMap { $0.expiresAt }.filter { $0 > now }.min()
    }

    /// Removes room trust that has ended. Returns true when something was removed.
    @discardableResult
    func purgeExpired() -> Bool {
        lock.lock()
        let now = Date()
        let expired = records.values.contains { $0.isExpired(now: now) }
        lock.unlock()
        guard expired else { return false }
        mutate { records in
            records = records.filter { !$0.value.isExpired(now: now) }
        }
        return true
    }

    /// Removes every temporary (room) trust. Rooms live only in memory, so after a relaunch
    /// no room is running here and nothing could end those trusts early. Returns true when
    /// something was removed.
    @discardableResult
    func forgetTemporary() -> Bool {
        lock.lock()
        let any = records.values.contains { $0.isTemporary }
        lock.unlock()
        guard any else { return false }
        mutate { records in
            records = records.filter { !$0.value.isTemporary }
        }
        return true
    }

    func isTrusted(_ deviceId: String) -> Bool {
        trustedIdentityKey(for: deviceId) != nil
    }

    // MARK: TrustProvider

    func trustedIdentityKey(for deviceId: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[deviceId], !record.isExpired() else { return nil }
        return record.identityKey
    }

    func isAutoAccept(deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[deviceId], !record.isExpired() else { return false }
        return record.autoAccept
    }

    var supportsTrustExpiry: Bool { true }

    func trustExpiry(for deviceId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[deviceId], !record.isExpired() else { return nil }
        return record.expiresAt
    }

    /// Room trust (§9.9): ends at `expiresAt` and never auto-accepts. A permanent pairing
    /// with the same key is never downgraded to temporary. nil `expiresAt` = permanent.
    func storeTrust(for peer: PeerInfo, autoAccept: Bool, expiresAt: Date?) {
        guard let expiresAt = expiresAt else {
            storeTrust(for: peer, autoAccept: autoAccept)
            return
        }
        mutate { records in
            let previous = records[peer.deviceId]
            let sameKey = previous?.identityKey == peer.identityKey
            if sameKey, let kept = previous, kept.expiresAt == nil { return }
            records[peer.deviceId] = TrustedDeviceRecord(
                deviceId: peer.deviceId, identityKey: peer.identityKey, name: peer.name, platform: peer.platform,
                pairedAt: Date(), lastUsedAt: Date(), autoAccept: false,
                lastHost: sameKey ? previous?.lastHost : nil,
                lastPort: sameKey ? previous?.lastPort : nil,
                expiresAt: expiresAt)
        }
    }

    func storeTrust(for peer: PeerInfo) {
        mutate { records in
            let previous = records[peer.deviceId]
            records[peer.deviceId] = TrustedDeviceRecord(
                deviceId: peer.deviceId, identityKey: peer.identityKey, name: peer.name, platform: peer.platform,
                pairedAt: Date(), lastUsedAt: Date(),
                autoAccept: previous?.identityKey == peer.identityKey ? (previous?.autoAccept ?? false) : false,
                lastHost: previous?.identityKey == peer.identityKey ? previous?.lastHost : nil,
                lastPort: previous?.identityKey == peer.identityKey ? previous?.lastPort : nil)
        }
    }

    /// After pairing; `autoAccept` is the "This is my device" choice.
    func storeTrust(for peer: PeerInfo, autoAccept: Bool) {
        storeTrust(for: peer)
        if autoAccept { setAutoAccept(true, for: peer.deviceId) }
    }

    func touch(peer: PeerInfo) {
        mutate { records in
            guard var record = records[peer.deviceId], record.identityKey == peer.identityKey,
                  !record.isExpired() else { return }
            record.name = peer.name
            record.lastUsedAt = Date()
            records[peer.deviceId] = record
        }
    }

    // MARK: User actions

    func forget(_ deviceId: String) {
        mutate { $0[deviceId] = nil }
    }

    /// Remembers where a paired device answered. Only for paired devices; the handshake
    /// still proves identity, so a stale address can only fail to connect.
    func rememberAddress(_ host: String, port: UInt16, for deviceId: String) {
        lock.lock()
        let same = records[deviceId].map { $0.lastHost == host && $0.lastPort == port } ?? true
        lock.unlock()
        guard !same else { return }
        mutate { records in
            records[deviceId]?.lastHost = host
            records[deviceId]?.lastPort = port
        }
    }

    func setAutoAccept(_ value: Bool, for deviceId: String) {
        mutate { records in records[deviceId]?.autoAccept = value }
    }

    private func mutate(_ change: (inout [String: TrustedDeviceRecord]) -> Void) {
        lock.lock()
        change(&records)
        let snapshot = Array(records.values)
        lock.unlock()
        save(snapshot)
        onChange?(all)
    }

    private func save(_ list: [TrustedDeviceRecord]) {
        AppPaths.ensureSupportDirectory()
        guard let data = try? Self.encoder.encode(list) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
