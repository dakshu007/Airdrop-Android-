import AppKit
import SwiftUI

/// The main CrossDrop window, owned by the app delegate so the menu bar icon,
/// notifications, Finder services and incoming requests can all bring it up.
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.title = "CrossDrop"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 620)
        window.setContentSize(NSSize(width: 1040, height: 700))
        window.delegate = self
        if !window.setFrameUsingName("CrossDropMain") { window.center() }
        window.setFrameAutosaveName("CrossDropMain")
        return window
    }
}
