import AppKit
import UniformTypeIdentifiers

/// Puts received files on the clipboard so ⌘V pastes them into the app the user was in.
enum PasteboardFiles {
    /// Images up to this size also go on the clipboard as image data, for apps that
    /// paste pictures but not files (chat apps, documents).
    static let maxInlineImage: Int64 = 40 * 1024 * 1024

    /// Returns the clipboard's new change count (so the clipboard watcher can ignore it),
    /// or nil when nothing was written.
    @discardableResult
    static func copy(_ urls: [URL]) -> Int? {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = existing.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if existing.count == 1, let type = UTType(filenameExtension: url.pathExtension.lowercased()),
               type.conforms(to: .image), let size = fileSize(url), size <= maxInlineImage,
               let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
                item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            }
            return item
        }
        guard pasteboard.writeObjects(items) else { return nil }
        return pasteboard.changeCount
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
    }
}

/// A light trackpad tap when a transfer is verified. Only Force Touch trackpads produce it,
/// and only while a finger rests on the trackpad; elsewhere the call does nothing.
enum Haptics {
    static func success() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
