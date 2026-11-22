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
    /// Set when an expiring drop's files were not moved to the Trash after all (moved or
    /// changed since they arrived, or the Trash refused them), saying why.
    var notDeletedReason: String? = nil
    /// Answer to a "Take Photo / Pick Photo" request from this Mac (§9.7).
    var isCaptureReply: Bool? = nil

    var isIncoming: Bool { direction == TransferDirection.incoming.rawValue }

    /// Received files still waiting to be moved to the Trash: this row holds their Keep button.
    var isPendingExpiry: Bool { isIncoming && deletesAt != nil && deletedAt == nil }

    /// "Deletes Nov 23, 10:42" / "Moved to Trash" for expiring drops, nil otherwise.
    var expiryText: String? {
        if deletedAt != nil { return "Moved to Trash" }
        if let reason = notDeletedReason { return reason }
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

/// Local transfer history: newest first, at most 200 entries, never uploaded. Entries of
/// expiring drops still waiting for the Trash are never trimmed or cleared away: their row
/// holds the only Keep button.
final class HistoryStore {
    static let limit = 200
    private let url = AppPaths.supportDirectory.appendingPathComponent("history.json")
    private(set) var entries: [HistoryEntry] = []

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let list = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = list
            trim()
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        trim()
        save()
    }

    /// Drops the oldest entries past the limit, skipping pending expiring drops.
    private func trim() {
        var excess = entries.count - Self.limit
        guard excess > 0 else { return }
        var index = entries.count - 1
        while excess > 0, index >= 0 {
            if !entries[index].isPendingExpiry {
                entries.remove(at: index)
                excess -= 1
            }
            index -= 1
        }
    }

    /// Changes one entry in place (paths after sorting, deletion of an expiring drop).
    func update(id: String, _ change: (inout HistoryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        save()
    }

    /// Clears the list except pending expiring drops (see the type's note).
    func clear() {
        entries = entries.filter { $0.isPendingExpiry }
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
