import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Compact panel shown from the menu bar icon, on the same mint backdrop as the main window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel

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
        VStack(alignment: .leading, spacing: 10) {
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
                Spacer(minLength: 0)
            }
            ReceiveModePicker()
        }
        .padding(.horizontal, CDSpacing.m)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: CDRadius.card)
    }

    @ViewBuilder
    private var devices: some View {
        VStack(alignment: .leading, spacing: CDSpacing.s) {
            HStack {
                Text(sendTitle)
                    .font(CDFont.poppins(12.5, .semibold))
                    .foregroundColor(CDPalette.textPrimary)
                Spacer()
                if model.hasSomethingToSend {
                    Button("Clear") { model.clearSelection() }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            if let text = model.pendingText {
                Label(text.text, systemImage: text.kind == .link ? "link" : "doc.plaintext")
                    .font(CDFont.caption)
                    .foregroundColor(CDPalette.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
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
                        if !model.hasSomethingToSend {
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
                            if device.isRemembered {
                                Text("not seen")
                                    .font(CDFont.poppins(10))
                                    .foregroundColor(CDPalette.textTertiary)
                                    .help("Not found nearby. CrossDrop will try the address that worked last time.")
                            }
                            Spacer()
                            Image(systemName: model.hasSomethingToSend ? "paperplane.fill" : "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(model.hasSomethingToSend ? .white : CDPalette.ink)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(model.hasSomethingToSend ? CDPalette.ink : Color(hex: 0xE9F4EC)))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(TileButtonStyle())
                    .accessibilityLabel(model.hasSomethingToSend ? "Send to \(device.name)" : "Choose files for \(device.name)")
                    .contextMenu {
                        Button("Send Clipboard to \(device.name)") { model.sendClipboard(to: device) }
                    }
                }
            }
        }
        .padding(CDSpacing.m)
        .glassPanel(cornerRadius: CDRadius.card)
    }

    private var sendTitle: String {
        if let text = model.pendingText { return text.kind == .link ? "Send link to" : "Send text to" }
        return model.selectedFiles.isEmpty ? "Nearby" : "Send \(Format.files(model.selectedFiles.count)) to"
    }

    private var footer: some View {
        HStack(spacing: CDSpacing.s) {
            Button {
                model.requestMainWindow()
            } label: {
                Label("Open CrossDrop", systemImage: "macwindow")
            }
            .buttonStyle(PrimaryButtonStyle())
            Button {
                model.takeClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(GlassButtonStyle())
            .help("Send what's on the clipboard (a link opens on the phone)")
            .accessibilityLabel("Send clipboard")
            Button {
                model.selectedTab = .devices
                model.showingPairSheet = true
                model.requestMainWindow()
            } label: {
                Image(systemName: "qrcode")
            }
            .buttonStyle(GlassButtonStyle())
            .help("Pair a phone with a QR code")
            .accessibilityLabel("Pair a phone")
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

/// Off / My Devices / Everyone, as a compact glass segmented control.
struct ReceiveModePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Picker("Who can send to this Mac", selection: Binding(get: { model.receiveMode }, set: { model.setReceiveMode($0) })) {
            ForEach(ReceiveMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("My Devices: only devices you paired, invisible to others. Everyone: anyone nearby can ask to send.")
        .accessibilityLabel("Who can send to this Mac")
    }
}
