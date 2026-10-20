import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

@main
struct CrossDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("CrossDrop", id: "main") {
            MainWindow()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
        .commands {
            CrossDropCommands(model: model)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        BundledFonts.register()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.configure()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        AppModel.shared.start()
    }

    @objc private func didWake(_ notification: Notification) {
        AppModel.shared.handleWake()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.requestMainWindow() }
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
        CommandMenu("Transfer") {
            Button("Turn Receiving On or Off") { model.setReceiving(!model.receivingEnabled) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
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

/// Menu bar icon. Also the one view that is always alive, so it opens the main
/// window when the model asks (incoming offer, pairing request).
struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.activeTransfers.isEmpty ? "arrow.up.arrow.down.circle" : "arrow.up.arrow.down.circle.fill")
            .accessibilityLabel("CrossDrop")
            .onReceive(model.$windowRequest.dropFirst()) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}
