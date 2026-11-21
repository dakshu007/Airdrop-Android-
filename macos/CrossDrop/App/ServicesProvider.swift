import AppKit

/// Finder › right-click › Services › "Send with CrossDrop". The files land in the
/// Send page, ready for the user to pick a device; nothing is sent by itself.
final class ServicesProvider: NSObject {
    @objc func sendFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files to send." as NSString
            return
        }
        DispatchQueue.main.async {
            let model = AppModel.shared
            model.addFiles(urls)
            model.selectedTab = .send
            model.requestMainWindow()
        }
    }
}
