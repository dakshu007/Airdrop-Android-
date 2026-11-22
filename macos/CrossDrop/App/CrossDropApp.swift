import SwiftUI
import AppKit
import Combine
#if canImport(CrossDropCore)
import CrossDropCore
#endif

@main
struct CrossDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    // The main window and the menu bar icon are AppKit-owned (see AppDelegate) so the
    // icon can take dropped files. SwiftUI keeps the menu commands.
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CrossDropCommands(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var mainWindow: MainWindowController?
    private var dripIsland: DripIslandController?
    private let services = ServicesProvider()
    private var subscriptions = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        BundledFonts.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.configure()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        let model = AppModel.shared
        let window = MainWindowController(model: model)
        mainWindow = window
        statusItem = StatusItemController(model: model)
        dripIsland = DripIslandController(model: model)
        model.$windowRequest
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.statusItem?.close()
                self?.mainWindow?.show()
            }
            .store(in: &subscriptions)

        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        model.start()
        window.show()
    }

    @objc private func didWake(_ notification: Notification) {
        AppModel.shared.handleWake()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.show() }
        return true
    }
}

struct CrossDropCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.selectedTab = .settings
                model.requestMainWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("Choose Files to Send…") {
                model.selectedTab = .send
                model.chooseFiles()
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { UIZoom.shared.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { UIZoom.shared.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { UIZoom.shared.reset() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
        CommandMenu("Transfer") {
            Button("Turn Receiving On or Off") { model.setReceiving(!model.receivingEnabled) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Send Clipboard…") {
                if model.takeClipboard() {
                    model.selectedTab = .send
                    model.requestMainWindow()
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Take Photo with Phone") { model.requestCapture(.photo) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Pick Photo from Phone") { model.requestCapture(.pick) }
            Divider()
            Button("Pair a Phone…") {
                model.selectedTab = .devices
                model.showingPairSheet = true
                model.requestMainWindow()
            }
            Divider()
            Button("Send") { model.selectedTab = .send }
                .keyboardShortcut("1", modifiers: .command)
            Button("Receive") { model.selectedTab = .receive }
                .keyboardShortcut("2", modifiers: .command)
            Button("Devices") { model.selectedTab = .devices }
                .keyboardShortcut("3", modifiers: .command)
            Button("History") { model.selectedTab = .history }
                .keyboardShortcut("4", modifiers: .command)
        }
    }
}

