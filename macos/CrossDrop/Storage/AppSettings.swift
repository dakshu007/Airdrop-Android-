import Foundation

/// UserDefaults-backed preferences. Reads are thread-safe.
enum AppSettings {
    private static let defaults = UserDefaults.standard

    enum Key {
        static let deviceName = "deviceName"
        static let receivingEnabled = "receivingEnabled"
        static let destinationPath = "destinationPath"
        static let autoOffMinutes = "autoOffMinutes"
        static let notificationsEnabled = "notificationsEnabled"
        static let soundOnDone = "soundOnDone"
        static let receiveMode = "receiveMode"
        static let heicToJpeg = "heicToJpeg"
    }

    /// "off", "mine" (paired devices only, invisible to others) or "everyone".
    /// Older versions stored only on/off; on meant visible to everyone.
    static var receiveMode: String {
        get {
            if let mode = defaults.string(forKey: Key.receiveMode), ["off", "mine", "everyone"].contains(mode) { return mode }
            return receivingEnabled ? "everyone" : "off"
        }
        set {
            defaults.set(newValue, forKey: Key.receiveMode)
            defaults.set(newValue != "off", forKey: Key.receivingEnabled)
        }
    }

    /// Also save a JPEG copy of received HEIC photos (the original is kept).
    static var heicToJpeg: Bool {
        get { defaults.object(forKey: Key.heicToJpeg) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.heicToJpeg) }
    }

    static var deviceName: String {
        get {
            let stored = defaults.string(forKey: Key.deviceName)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored = stored, !stored.isEmpty { return stored }
            return Host.current().localizedName ?? "Mac"
        }
        set { defaults.set(newValue, forKey: Key.deviceName) }
    }

    static var receivingEnabled: Bool {
        get { defaults.object(forKey: Key.receivingEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.receivingEnabled) }
    }

    static var destination: URL {
        get {
            if let path = defaults.string(forKey: Key.destinationPath) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
            return AppPaths.defaultDownloads
        }
        set { defaults.set(newValue.path, forKey: Key.destinationPath) }
    }

    /// 0 means never switch receiving off automatically.
    static var autoOffMinutes: Int {
        get { defaults.object(forKey: Key.autoOffMinutes) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: Key.autoOffMinutes) }
    }

    static var notificationsEnabled: Bool {
        get { defaults.object(forKey: Key.notificationsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// A soft drop sound when a transfer finishes and is verified.
    static var soundOnDone: Bool {
        get { defaults.object(forKey: Key.soundOnDone) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundOnDone) }
    }
}
