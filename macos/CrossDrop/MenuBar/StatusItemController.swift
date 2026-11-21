import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// The menu bar icon. Click it for the CrossDrop panel; drag files from Finder onto
/// it to get them ready to send (the panel opens with them, pick a device).
final class StatusItemController: NSObject, NSWindowDelegate, NSDraggingDestination {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var subscriptions = Set<AnyCancellable>()
    private var dragHighlight = false

    init(model: AppModel) {
        self.model = model
        super.init()
        let hosting = NSHostingController(rootView: MenuBarView().environmentObject(model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle(_:))
            button.setAccessibilityLabel("CrossDrop")
            button.toolTip = "CrossDrop — click to open, or drop files here to send"
            // Dropping onto the menu bar icon: the button's window takes drags and hands
            // them to us as its delegate.
            button.window?.registerForDraggedTypes([.fileURL])
            button.window?.delegate = self
        }
        updateIcon(active: false)
        model.$transfers
            .map { $0.contains { !$0.snapshot.phase.isFinished } }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] active in self?.updateIcon(active: active) }
            .store(in: &subscriptions)
    }

    private func updateIcon(active: Bool) {
        let name = dragHighlight ? "tray.and.arrow.down.fill"
            : (active ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "CrossDrop")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            show()
        }
    }

    func show() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        popover.performClose(nil)
    }

    // MARK: Dragging onto the icon

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        dragHighlight = true
        statusItem.button?.highlight(true)
        updateIcon(active: false)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        endDragHighlight()
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        endDragHighlight()
        guard !urls.isEmpty else { return false }
        DispatchQueue.main.async {
            self.model.addFiles(urls)
            self.show()
        }
        return true
    }

    private func endDragHighlight() {
        dragHighlight = false
        statusItem.button?.highlight(false)
        updateIcon(active: model.transfers.contains { !$0.snapshot.phase.isFinished })
    }
}
