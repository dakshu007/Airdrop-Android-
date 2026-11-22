import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// The menu bar icon. Click it for the CrossDrop panel; drag files from Finder onto
/// it to get them ready to send (the panel opens with them, pick a device). Right-click
/// (or Control-click) for a quick menu: Take Photo with the phone, the Shelf, sends
/// waiting for a device, receiving mode, Drip Rooms and the clipboard / island switches.
final class StatusItemController: NSObject, NSWindowDelegate, NSDraggingDestination, NSMenuDelegate {
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
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("CrossDrop")
            button.toolTip = "CrossDrop — click to open, right-click for quick actions, or drop files here to send"
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
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showQuickMenu()
            return
        }
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

    // MARK: Quick menu (right-click)

    private func showQuickMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Take Photo / Pick Photo with the phone (§9.7)
        if let capture = model.capture, capture.isActive {
            menu.addItem(item("Stop Waiting for \(capture.deviceName)", symbol: "xmark.circle", action: #selector(stopCapture)))
        } else if let phone = model.capturePhone {
            menu.addItem(item("Take Photo with \(phone.name)", symbol: "camera", action: #selector(takePhoto)))
            menu.addItem(item("Pick Photo from \(phone.name)", symbol: "photo.on.rectangle", action: #selector(pickPhoto)))
        } else {
            let unavailable = item("Take Photo with Phone", symbol: "camera", action: nil)
            unavailable.isEnabled = false
            unavailable.toolTip = "Pair your phone first; it needs CrossDrop open on the same Wi-Fi."
            menu.addItem(unavailable)
        }
        menu.addItem(.separator())

        // Shelf
        let shelfItem = item(model.shelf.isEmpty ? "Shelf is Empty" : "Shelf (\(model.shelf.count))",
                             symbol: "tray.full", action: nil)
        if model.shelf.isEmpty {
            shelfItem.isEnabled = false
            shelfItem.toolTip = "Drag files to the top of the screen and drop them on the Shelf to keep them here."
        } else {
            let sub = NSMenu()
            for entry in model.shelf.prefix(15) {
                let row = item(entry.name, symbol: nil, action: #selector(revealShelfItem(_:)))
                row.representedObject = entry.id
                row.image = NSWorkspace.shared.icon(forFile: entry.path)
                row.image?.size = NSSize(width: 16, height: 16)
                row.isEnabled = entry.exists
                row.toolTip = entry.exists ? "Show in Finder" : "No longer where it was"
                sub.addItem(row)
            }
            sub.addItem(.separator())
            sub.addItem(item("Add All to Send", symbol: "paperplane", action: #selector(shelfToSend)))
            sub.addItem(item("Clear Shelf", symbol: "trash", action: #selector(clearShelf)))
            shelfItem.submenu = sub
        }
        menu.addItem(shelfItem)

        // Send when nearby
        if !model.sendQueue.isEmpty {
            let queued = item("Waiting to Send (\(model.sendQueue.count))", symbol: "clock.arrow.circlepath", action: nil)
            let sub = NSMenu()
            for entry in model.sendQueue {
                let row = item("Cancel: \(entry.summary) to \(entry.deviceName)", symbol: nil, action: #selector(cancelQueued(_:)))
                row.representedObject = entry.id
                sub.addItem(row)
            }
            sub.addItem(.separator())
            sub.addItem(item("Try Now", symbol: "arrow.clockwise", action: #selector(retryQueue)))
            queued.submenu = sub
            menu.addItem(queued)
        }
        menu.addItem(.separator())

        // Who can send
        for mode in ReceiveMode.allCases {
            let row = item("Receiving: \(mode.title)", symbol: nil, action: #selector(setMode(_:)))
            row.representedObject = mode.rawValue
            row.state = model.receiveMode == mode ? .on : .off
            menu.addItem(row)
        }
        menu.addItem(.separator())

        // Drip Room (§9.9)
        if let room = model.currentRoom {
            menu.addItem(item("End Room \u{201C}\(room.name)\u{201D}", symbol: "person.2.slash", action: #selector(endRoom)))
        } else {
            menu.addItem(item("Start a Drip Room…", symbol: "person.2", action: #selector(startRoom)))
        }
        let island = item("Drip Island While Dragging", symbol: nil, action: #selector(toggleIsland))
        island.state = model.dripIslandEnabled ? .on : .off
        menu.addItem(island)
        let clipboard = item("Offer What I Copy to My Phone", symbol: nil, action: #selector(toggleClipboard))
        clipboard.state = model.offerClipboardToPhone ? .on : .off
        clipboard.toolTip = "Sends text you copy to your phone (paired as yours). Off by default."
        menu.addItem(clipboard)
        menu.addItem(.separator())

        menu.addItem(item("Open CrossDrop", symbol: "macwindow", action: #selector(openMain)))
        let quit = NSMenuItem(title: "Quit CrossDrop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Back to the panel on a normal click.
        statusItem.menu = nil
    }

    private func item(_ title: String, symbol: String?, action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol = symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func takePhoto() { model.requestCapture(.photo) }
    @objc private func pickPhoto() { model.requestCapture(.pick) }
    @objc private func stopCapture() { model.cancelCapture() }

    @objc private func revealShelfItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let entry = model.shelf.first(where: { $0.id == id }) else { return }
        model.revealShelfItems([entry])
    }

    @objc private func shelfToSend() {
        model.addShelfToSelection()
        model.requestMainWindow()
    }

    @objc private func clearShelf() { model.clearShelf() }

    @objc private func cancelQueued(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let entry = model.sendQueue.first(where: { $0.id == id }) else { return }
        model.cancelQueued(entry)
    }

    @objc private func retryQueue() { model.retryQueueNow() }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ReceiveMode(rawValue: raw) else { return }
        model.setReceiveMode(mode)
    }

    @objc private func startRoom() {
        model.selectedTab = .devices
        model.showingRoomSheet = true
        model.requestMainWindow()
    }

    @objc private func endRoom() { model.endRoom() }
    @objc private func toggleIsland() { model.setDripIsland(!model.dripIslandEnabled) }
    @objc private func toggleClipboard() { model.setOfferClipboardToPhone(!model.offerClipboardToPhone) }
    @objc private func openMain() { model.requestMainWindow() }

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
