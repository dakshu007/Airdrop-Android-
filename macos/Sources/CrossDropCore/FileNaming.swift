import Foundation

/// Receiver-side file name rules (docs/protocol-v1.md §6.5).
public enum FileNaming {
    private static let forbidden: Set<UInt32> = Set("<>:\"|?*".unicodeScalars.map { $0.value })

    public static func sanitize(_ name: String) -> String {
        var scalars = Array(name.precomposedStringWithCanonicalMapping.unicodeScalars)
        if let cut = scalars.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            scalars = Array(scalars[(cut + 1)...])
        }
        scalars = scalars.filter { s in
            !(s.value <= 0x1F || (0x7F...0x9F).contains(s.value))
        }
        scalars = scalars.map { s in forbidden.contains(s.value) ? Unicode.Scalar(UInt8(ascii: "_")) : s }
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        while let first = scalars.first, first == "." { scalars.removeFirst() }
        if scalars.isEmpty { return "file" }
        if utf8Length(scalars) <= 200 { return string(scalars) }

        var ext: [Unicode.Scalar] = []
        if let dot = scalars.lastIndex(of: "."), dot > 0 {
            let candidate = Array(scalars[dot...])
            if utf8Length(candidate) <= 16 { ext = candidate }
        }
        let stem = Array(scalars[0..<(scalars.count - ext.count)])
        let budget = 200 - utf8Length(ext)
        var kept: [Unicode.Scalar] = []
        var used = 0
        for s in stem {
            let width = utf8Width(s)
            if used + width > budget { break }
            kept.append(s)
            used += width
        }
        return string(kept + ext)
    }

    /// Splits "photo.jpg" into ("photo", ".jpg"); no extension for leading-dot or dot-less names.
    public static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// Moves `temporary` into `directory` under `name`, adding " (n)" before the
    /// extension instead of ever overwriting an existing item.
    public static func moveToUniqueDestination(_ temporary: URL, directory: URL, name: String) throws -> URL {
        let fm = FileManager.default
        let parts = splitExtension(name)
        for index in 0..<10_000 {
            let candidate = index == 0 ? name : "\(parts.stem) (\(index))\(parts.ext)"
            let url = directory.appendingPathComponent(candidate, isDirectory: false)
            // attributesOfItem uses lstat, so dangling symlinks count as taken.
            if (try? fm.attributesOfItem(atPath: url.path)) != nil { continue }
            do {
                try fm.moveItem(at: temporary, to: url)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                throw CrossDropError.violation(ErrorCode.storageError, "move failed")
            }
        }
        throw CrossDropError.violation(ErrorCode.storageError, "no free name")
    }

    /// Bytes available for new files on the volume holding `url`.
    public static func availableCapacity(at url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage, capacity > 0 {
            return capacity
        }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let free = attributes[.systemFreeSize] as? NSNumber {
            return free.int64Value
        }
        return nil
    }

    static func utf8Width(_ s: Unicode.Scalar) -> Int {
        switch s.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x10000: return 3
        default: return 4
        }
    }

    static func utf8Length(_ scalars: [Unicode.Scalar]) -> Int {
        scalars.reduce(0) { $0 + utf8Width($1) }
    }

    static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
