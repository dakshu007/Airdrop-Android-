import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Optional: saves a JPEG copy next to each received HEIC photo, for apps that
/// don't open HEIC. The original is never changed or removed.
enum HeicConverter {
    /// Returns the JPEG copies it wrote.
    @discardableResult
    static func saveJpegCopies(of urls: [URL]) -> [URL] {
        var written: [URL] = []
        for url in urls where ["heic", "heif"].contains(url.pathExtension.lowercased()) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else { continue }
            let target = uniqueURL(for: url.deletingPathExtension().appendingPathExtension("jpg"))
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            // Copies the image with its metadata (orientation, date, location if present).
            CGImageDestinationAddImageFromSource(destination, source, 0,
                                                 [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                written.append(target)
            } else {
                try? FileManager.default.removeItem(at: target)
            }
        }
        return written
    }

    /// "photo.jpg", or "photo (1).jpg" when that name is taken; never overwrites.
    private static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for n in 1..<1000 {
            let candidate = dir.appendingPathComponent("\(stem) (\(n)).jpg")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem) \(UUID().uuidString.prefix(6)).jpg")
    }
}
