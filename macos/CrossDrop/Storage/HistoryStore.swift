import Foundation
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct HistoryFile: Codable, Equatable, Hashable {
    var name: String
    var size: Int64
    /// Saved location for received files.
    var path: String?
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id: String
    var direction: String
    var peerName: String
    var platform: String
    /// completed | failed | cancelled | rejected
    var status: String
    var files: [HistoryFile]
    var totalBytes: Int64
    var finishedAt: Date
    var errorCode: String?
    /// "files", "link" or "text" (absent in older entries = files).
    var kind: String?
    /// The link itself for link entries; text content is never stored.
    var link: String?
    /// Expiring drop (§9.8): seconds after arrival the sender asked for deletion.
    var expiresAfter: Int64? = nil
    /// Incoming expiring drop: when CrossDrop moves the saved files to the Trash.
    var deletesAt: Date? = nil
    /// Set once those files were moved to the Trash.
    var deletedAt: Date? = nil
    /// Answer to a "Take Photo / Pick Photo" request from this Mac (§9.7).
    var isCaptureReply: Bool? = nil

    var isIncoming: Bool { direction == TransferDirection.incoming.rawValue }

    /// "Deletes Nov 23, 10:42" / "Deleted" for expiring drops, nil otherwise.
    var expiryText: String? {
        if deletedAt != nil { return "Moved to Trash" }
        if let date = deletesAt {
            return "Deletes " + date.formatted(date: .abbreviated, time: .shortened)
        }
        if !isIncoming, let seconds = expiresAfter {
            let hours = Int((Double(seconds) / 3600).rounded())
            return hours >= 1 ? "Auto-deletes \(hours) h after arrival" : "Auto-deletes after arrival"
        }
        return nil
    }
}

/// Local transfer history: newest first, at most 200 entries, never uploaded.
final class HistoryStore {
    static let limit = 200
    private let url = AppPaths.supportDirectory.appendingPathComponent("history.json")
    private(set) var entries: [HistoryEntry] = []

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let list = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = Array(list.prefix(Self.limit))
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries = Array(entries.prefix(Self.limit)) }
        save()
    }

    /// Changes one entry in place (paths after sorting, deletion of an expiring drop).
    func update(id: String, _ change: (inout HistoryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        AppPaths.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
