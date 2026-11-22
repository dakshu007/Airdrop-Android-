import Foundation
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// A small JSON list in Application Support (owner-only permissions), loaded once and
/// rewritten atomically on every change. Main thread only. Nothing here leaves the Mac.
final class JSONListFile<Element: Codable> {
    private let url: URL

    init(name: String) {
        url = AppPaths.supportDirectory.appendingPathComponent(name)
    }

    func load() -> [Element] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([Element].self, from: data)) ?? []
    }

    func save(_ list: [Element]) {
        AppPaths.ensureSupportDirectory()
        if list.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? Self.encoder.encode(list) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Shelf

/// A file or folder stashed on the Shelf (the "Pocket"). Only its path is kept: the app is
/// not sandboxed, so no security-scoped bookmark is needed. The file itself is not copied.
struct ShelfItem: Codable, Identifiable, Equatable {
    let id: UUID
    let path: String
    let name: String
    /// Size when stashed (0 for folders).
    let size: Int64
    let isFolder: Bool
    let addedAt: Date

    var url: URL { URL(fileURLWithPath: path, isDirectory: isFolder) }

    /// False once the file was moved or deleted outside CrossDrop.
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    /// For dragging the item out of CrossDrop (Finder, Mail, any app that takes files).
    var itemProvider: NSItemProvider {
        NSItemProvider(object: url as NSURL)
    }
}

// MARK: - Send when nearby

/// A send to a paired device that wasn't reachable, delivered when it shows up again.
/// Files are referenced by path (never copied); text is kept only until it is delivered.
struct QueuedSend: Codable, Identifiable, Equatable {
    struct File: Codable, Equatable {
        let path: String
        let name: String
        /// Folders above the file inside a dropped folder (§9.1).
        let folders: [String]
    }

    let id: UUID
    let deviceId: String
    var deviceName: String
    let platform: String
    /// "files", "link" or "text".
    let kind: String
    let files: [File]
    let text: String?
    let expiresAfter: Int64?
    let createdAt: Date
    var attempts: Int = 0
    var lastAttemptAt: Date? = nil

    var offerKind: OfferKind { OfferKind(rawValue: kind) ?? .files }

    var summary: String {
        switch offerKind {
        case .link: return "A link"
        case .text: return "Some text"
        case .files: return Format.files(files.count)
        }
    }
}

// MARK: - Expiring drops

/// A received file the sender asked to have deleted (§9.8). CrossDrop moves it to the
/// Trash (never deletes outright) once `deleteAt` has passed, and only if the file at that
/// path is still the one that arrived: same file number (inode), size and modification
/// date. A different file saved under that name later, even one of the same size, is safe.
struct ExpiringFile: Codable, Identifiable, Equatable {
    let id: UUID
    let transferId: String
    var path: String
    let size: Int64
    let deleteAt: Date
    /// The file's number on its volume when it was registered (nil in older records).
    var fileNumber: UInt64? = nil
    /// Its modification date then (nil in older records).
    var modifiedAt: Date? = nil

    /// Reads the identity of the file at `url`: size, file number and modification date.
    static func identity(of url: URL) -> (size: Int64, fileNumber: UInt64?, modifiedAt: Date?)? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
              let size = values.fileSize else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        return (Int64(size), fileNumber, values.contentModificationDate)
    }

    /// True when the file at `path` is still the one that arrived. Records written before
    /// file numbers were kept can't prove that, so they are never trashed.
    var isUnchanged: Bool {
        guard let fileNumber = fileNumber, let modifiedAt = modifiedAt,
              let now = Self.identity(of: URL(fileURLWithPath: path)),
              now.size == size, now.fileNumber == fileNumber, let modified = now.modifiedAt else { return false }
        // Dates are stored to the second (ISO 8601).
        return abs(modified.timeIntervalSince(modifiedAt)) < 1
    }
}
