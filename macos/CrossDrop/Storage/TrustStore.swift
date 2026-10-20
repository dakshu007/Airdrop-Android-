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

    var fingerprint: String { CDCrypto.fingerprint(of: identityKey) }
}

/// Paired devices, persisted as JSON in Application Support. The file holds
/// public keys only. Thread-safe: the engine calls it from background threads.
final class TrustStore: TrustProvider {
    private let lock = NSLock()
    private var records: [String: TrustedDeviceRecord] = [:]
    private let url = AppPaths.supportDirectory.appendingPathComponent("trusted-devices.json")
    /// Called on an arbitrary thread after every change.
    var onChange: (([TrustedDeviceRecord]) -> Void)?

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? Self.decoder.decode([TrustedDeviceRecord].self, from: data) {
            for record in list where CDCrypto.deviceId(of: record.identityKey) == record.deviceId {
                records[record.deviceId] = record
            }
        }
    }

    var all: [TrustedDeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records.values.sorted { ($0.lastUsedAt ?? $0.pairedAt) > ($1.lastUsedAt ?? $1.pairedAt) }
    }

    func isTrusted(_ deviceId: String) -> Bool {
        trustedIdentityKey(for: deviceId) != nil
    }

    // MARK: TrustProvider

    func trustedIdentityKey(for deviceId: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return records[deviceId]?.identityKey
    }

    func isAutoAccept(deviceId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return records[deviceId]?.autoAccept ?? false
    }

    func storeTrust(for peer: PeerInfo) {
        mutate { records in
            let previous = records[peer.deviceId]
            records[peer.deviceId] = TrustedDeviceRecord(
                deviceId: peer.deviceId, identityKey: peer.identityKey, name: peer.name, platform: peer.platform,
                pairedAt: Date(), lastUsedAt: Date(),
                autoAccept: previous?.identityKey == peer.identityKey ? (previous?.autoAccept ?? false) : false)
        }
    }

    func touch(peer: PeerInfo) {
        mutate { records in
            guard var record = records[peer.deviceId], record.identityKey == peer.identityKey else { return }
            record.name = peer.name
            record.lastUsedAt = Date()
            records[peer.deviceId] = record
        }
    }

    // MARK: User actions

    func forget(_ deviceId: String) {
        mutate { $0[deviceId] = nil }
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
