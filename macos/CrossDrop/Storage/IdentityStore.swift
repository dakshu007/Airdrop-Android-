import Foundation
import Security
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Keeps the device's private identity key in the login Keychain.
///
/// Ad-hoc signed builds change their code signature on every update, so macOS
/// may ask once whether CrossDrop may keep using its key ("Always Allow").
/// If the Keychain is unavailable the key falls back to a 0600 file in
/// Application Support and Settings says so.
enum IdentityStore {
    private static let service = "app.crossdrop.identity"
    private static let account = "device-identity-p256"

    enum Location: Equatable {
        case keychain
        case file
        case ephemeral
    }

    static func loadOrCreate() -> (DeviceIdentity, Location) {
        if let raw = try? readKeychain(), raw.count == 32, let identity = try? DeviceIdentity(rawPrivateKey: raw) {
            return (identity, .keychain)
        }
        if let raw = readFile(), let identity = try? DeviceIdentity(rawPrivateKey: raw) {
            return (identity, .file)
        }
        let identity = DeviceIdentity.generate()
        if (try? writeKeychain(identity.rawPrivateKey)) != nil {
            return (identity, .keychain)
        }
        if writeFile(identity.rawPrivateKey) {
            return (identity, .file)
        }
        return (identity, .ephemeral)
    }

    private static func readKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    private static func writeKeychain(_ raw: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "CrossDrop device identity",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: raw,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private static var fileURL: URL { AppPaths.supportDirectory.appendingPathComponent("identity.key") }

    private static func readFile() -> Data? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let raw = Hex.decode(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return raw?.count == 32 ? raw : nil
    }

    private static func writeFile(_ raw: Data) -> Bool {
        AppPaths.ensureSupportDirectory()
        return FileManager.default.createFile(atPath: fileURL.path, contents: Data(Hex.encode(raw).utf8),
                                              attributes: [.posixPermissions: 0o600])
    }
}

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CrossDrop", isDirectory: true)
    }

    static func ensureSupportDirectory() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    static var defaultDownloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }
}
