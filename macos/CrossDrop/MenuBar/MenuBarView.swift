import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Compact panel shown from the menu bar icon.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.m) {
            HStack {
                Text("CrossDrop").font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                ReceiveToggle(compact: true)
            }

            DropZone(compact: true)

            if !model.selectedFiles.isEmpty {
                quickSend
            } else if !model.networkAvailable {
                hint("Not connected to Wi-Fi.", symbol: "wifi.slash")
            } else if model.discoveryStatus == .localNetworkDenied {
                hint("Allow Local Network access in System Settings › Privacy & Security.", symbol: "lock.shield")
            } else if model.nearby.isEmpty {
                hint("Looking for nearby devices…", symbol: "dot.radiowaves.left.and.right")
            } else {
                hint("Nearby: " + model.nearby.map { $0.name }.joined(separator: ", "), symbol: "dot.radiowaves.left.and.right")
            }

            if !model.activeTransfers.isEmpty {
                VStack(spacing: CDSpacing.s) {
                    ForEach(model.activeTransfers.prefix(3)) { item in
                        TransferCard(item: item, compact: true)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open CrossDrop") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(GlassButtonStyle())
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(CDSpacing.l)
        .frame(width: 360)
        .onAppear { model.beginDiscovery() }
        .onDisappear { model.endDiscovery() }
    }

    private var quickSend: some View {
        VStack(alignment: .leading, spacing: CDSpacing.s) {
            HStack {
                Text("\(Format.files(model.selectedFiles.count)) · \(Format.bytes(model.selectedTotalBytes))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Clear") { model.clearSelection() }
                    .buttonStyle(GlassButtonStyle())
            }
            if model.nearby.isEmpty {
                hint("No devices nearby yet. Turn on Receiving on your phone.", symbol: "dot.radiowaves.left.and.right")
            } else {
                Text("Send to").font(.system(size: 11)).foregroundColor(.secondary)
                ForEach(model.nearby) { device in
                    Button {
                        model.sendSelection(to: device)
                    } label: {
                        HStack(spacing: CDSpacing.s) {
                            DeviceAvatar(platform: device.platform, size: 26)
                            Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            if model.isTrusted(device.deviceId) {
                                Image(systemName: "checkmark.seal.fill").foregroundColor(CDPalette.mint)
                                    .accessibilityLabel("Paired")
                            }
                            Image(systemName: "paperplane.fill").foregroundColor(CDPalette.sky)
                        }
                        .padding(.horizontal, CDSpacing.m)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: CDRadius.small, style: .continuous)
                            .fill(Color.primary.opacity(0.05)))
                        .contentShape(RoundedRectangle(cornerRadius: CDRadius.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send to \(device.name)")
                }
            }
        }
    }

    private func hint(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundColor(.secondary)
            Text(text).font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
