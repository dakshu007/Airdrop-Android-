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
        .defaultSize(width: 920, height: 700)
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

        Settings {
            ScrollView {
                SettingsView()
                    .padding(CDSpacing.xl)
            }
            .background(GlassBackdrop())
            .environmentObject(model)
            .frame(width: 580, height: 640)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        CommandGroup(replacing: .newItem) {
            Button("Choose Files to Send…") { model.chooseFiles() }
                .keyboardShortcut("o", modifiers: .command)
        }
        CommandMenu("Transfer") {
            Button("Turn Receiving On or Off") { model.setReceiving(!model.receivingEnabled) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            ForEach(Array(AppTab.allCases.enumerated()), id: \.offset) { index, tab in
                Button(tab.title) { model.selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
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
