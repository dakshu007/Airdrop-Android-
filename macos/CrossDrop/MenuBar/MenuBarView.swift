import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Compact panel shown from the menu bar icon, on the same mint backdrop as the main window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: CDSpacing.m) {
                header
                DropZone(compact: true)
                devices
                if !model.activeTransfers.isEmpty {
                    VStack(spacing: CDSpacing.s) {
                        ForEach(model.activeTransfers.prefix(3)) { item in
                            TransferCard(item: item, compact: true)
                        }
                    }
                }
                footer
            }
            .padding(CDSpacing.m)
            .frame(width: 360)
        }
        .background(MintBackdrop(mood: model.activeTransfers.isEmpty ? .idle : .active))
        .environment(\.colorScheme, .light)
        .onAppear { model.beginDiscovery() }
        .onDisappear { model.endDiscovery() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("CrossDrop")
                    .font(CDFont.poppins(15, .bold))
                    .foregroundColor(CDPalette.textPrimary)
                Text(ReceiverText.detail(model))
                    .font(CDFont.poppins(10.5))
                    .foregroundColor(CDPalette.textSecondary)
                    .lineLimit(1)
            }
            Toggle(isOn: Binding(get: { model.receivingEnabled }, set: { model.setReceiving($0) })) {
                EmptyView()
            }
            .toggleStyle(GlassToggleStyle())
            .accessibilityLabel("Receiving")
        }
        .padding(.horizontal, CDSpacing.m)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: CDRadius.card)
    }

    @ViewBuilder
    private var devices: some View {
        VStack(alignment: .leading, spacing: CDSpacing.s) {
            HStack {
                Text(model.selectedFiles.isEmpty ? "Nearby" : "Send \(Format.files(model.selectedFiles.count)) to")
                    .font(CDFont.poppins(12.5, .semibold))
                    .foregroundColor(CDPalette.textPrimary)
                Spacer()
                if !model.selectedFiles.isEmpty {
                    Button("Clear") { model.clearSelection() }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            if !model.networkAvailable {
                HStack(spacing: CDSpacing.m) {
                    DripView(pose: .nowifi, size: 56, motion: .still)
                    hint("Not connected to Wi-Fi. Join the same network as your phone.", symbol: "wifi.slash")
                }
            } else if model.discoveryStatus == .localNetworkDenied {
                hint("Allow Local Network access in System Settings › Privacy & Security.", symbol: "lock.shield")
            } else if model.nearby.isEmpty {
                HStack(spacing: CDSpacing.m) {
                    DripView(pose: .searching, size: 56, motion: .bob)
                    Text("Looking for nearby devices. Turn on Receiving on your phone.")
                        .font(CDFont.caption)
                        .foregroundColor(CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(model.nearby) { device in
                    Button {
                        if model.selectedFiles.isEmpty {
                            model.selectedDeviceId = device.deviceId
                            model.chooseFiles()
                        } else {
                            model.sendSelection(to: device)
                        }
                    } label: {
                        HStack(spacing: CDSpacing.s) {
                            DeviceAvatar(platform: device.platform, size: 28)
                            Text(device.name)
                                .font(CDFont.poppins(12.5, .medium))
                                .foregroundColor(CDPalette.textPrimary)
                                .lineLimit(1)
                            if model.isTrusted(device.deviceId) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(CDPalette.mint)
                                    .accessibilityLabel("Paired")
                            }
                            Spacer()
                            Image(systemName: model.selectedFiles.isEmpty ? "plus" : "paperplane.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(model.selectedFiles.isEmpty ? CDPalette.ink : .white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(model.selectedFiles.isEmpty ? Color(hex: 0xE9F4EC) : CDPalette.ink))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(TileButtonStyle())
                    .accessibilityLabel(model.selectedFiles.isEmpty ? "Choose files for \(device.name)" : "Send to \(device.name)")
                }
            }
        }
        .padding(CDSpacing.m)
        .glassPanel(cornerRadius: CDRadius.card)
    }

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open CrossDrop", systemImage: "macwindow")
            }
            .buttonStyle(PrimaryButtonStyle())
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(GlassButtonStyle())
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 4)
    }

    private func hint(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundColor(CDPalette.textSecondary)
            Text(text)
                .font(CDFont.caption)
                .foregroundColor(CDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
