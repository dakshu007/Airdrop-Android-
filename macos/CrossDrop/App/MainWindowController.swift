import AppKit
import SwiftUI

/// The main CrossDrop window, owned by the app delegate so the menu bar icon,
/// notifications, Finder services and incoming requests can all bring it up.
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        super.init()
        // View › Zoom In shows ⌘+ (⇧⌘=). Most people press ⌘= without Shift, as in
        // browsers, so take that too while this window is key.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let window = self.window, event.window === window else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return event }
            guard let key = event.charactersIgnoringModifiers, key == "=" || key == "+" else { return event }
            UIZoom.shared.zoomIn()
            return nil
        }
    }

    deinit {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: MainWindow().environmentObject(model))
        // Only the minimum size comes from SwiftUI; the window itself decides how large
        // it is (the UI scales with it), so resizing, zoom and full screen stay free.
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "CrossDrop"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: CDLayout.minWindow.width, height: CDLayout.minWindow.height)
        window.setContentSize(NSSize(width: CDLayout.defaultWindow.width, height: CDLayout.defaultWindow.height))
        // The green button enters full screen; Option-click (or a double-click on the
        // top edge) zooms to fill the screen. Either way the UI scales up with it.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.delegate = self
        if !window.setFrameUsingName("CrossDropMain") { window.center() }
        window.setFrameAutosaveName("CrossDropMain")
        return window
    }
}
