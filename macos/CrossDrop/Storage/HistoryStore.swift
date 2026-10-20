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

    var isIncoming: Bool { direction == TransferDirection.incoming.rawValue }
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
