import Foundation
import UniformTypeIdentifiers

/// "Sort by type" (off by default): after a transfer is verified, single received files
/// move to a folder that suits them. Files inside a folder transfer keep their structure
/// and stay where they were saved. Never overwrites: a taken name gets " (1)", " (2)"…
enum SmartArrival {
    /// The folder `url` belongs in, or nil to leave it in the receive destination.
    static func folder(for url: URL, deviceName: String, date: Date) -> URL? {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        // Photos and screenshots are images; a name alone ("Screenshot tool.dmg") never decides.
        if type?.conforms(to: .image) ?? false {
            return picturesFolder(deviceName: deviceName, date: date)
        }
        if let type = type, documentTypes.contains(where: { type.conforms(to: $0) }) {
            return home(.documentDirectory, fallback: "Documents").appendingPathComponent("CrossDrop", isDirectory: true)
        }
        return nil
    }

    /// ~/Pictures/CrossDrop/From <device> – <yyyy-MM-dd>
    static func picturesFolder(deviceName: String, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let folderName = "From \(safeComponent(deviceName)) \u{2013} \(formatter.string(from: date))"
        return home(.picturesDirectory, fallback: "Pictures")
            .appendingPathComponent("CrossDrop", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Moves `url` into `folder` under a unique name. Returns the new location, or nil when
    /// it could not be moved (the file then stays where it was saved).
    static func move(_ url: URL, into folder: URL) -> URL? {
        let fm = FileManager.default
        guard url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { return nil }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // Retry with the next free name if another file appears there in the meantime.
        for _ in 0..<3 {
            let target = uniqueURL(in: folder, name: url.lastPathComponent)
            do {
                try fm.moveItem(at: url, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }

    /// `name`, or "name (1).ext", "name (2).ext"… when taken.
    static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for n in 1..<10_000 {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let suffix = UUID().uuidString.prefix(8)
        return folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)")
    }

    private static let documentTypes: [UTType] = [
        .pdf, .rtf, .rtfd, .plainText, .presentation, .spreadsheet, .compositeContent, .epub,
    ]

    private static func home(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(fallback, isDirectory: true)
    }

    /// A device name safe as one folder name: no slashes or colons, no leading dot, at most 60 characters.
    static func safeComponent(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var printable = String.UnicodeScalarView()
        printable.append(contentsOf: text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        text = String(printable)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(".") { text.removeFirst() }
        text = String(text.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Phone" : text
    }
}
