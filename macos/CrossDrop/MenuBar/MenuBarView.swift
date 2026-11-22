import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Compact panel shown from the menu bar icon, on the same mint backdrop as the main window.
/// Always drawn at 100 % (the zoom applies to the main window only), using the same
/// tokens and rhythm as the main window.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: ui.m) {
                header
                DropZone(compact: true)
                devices
                if model.capture != nil || model.capturePhone != nil {
                    PhoneCaptureCard(compact: true)
                }
                MenuBarShelf()
                if !model.sendQueue.isEmpty {
                    SendQueueCard(compact: true)
                }
                if let room = model.currentRoom {
                    MenuBarRoomRow(room: room)
                }
                if !model.activeTransfers.isEmpty {
                    VStack(spacing: ui.s) {
                        ForEach(model.activeTransfers.prefix(3)) { item in
                            TransferCard(item: item, compact: true)
                        }
                    }
                }
                footer
            }
            .padding(ui.l)
            .frame(width: ui(368))
        }
        .background(MintBackdrop(mood: model.activeTransfers.isEmpty ? .idle : .active))
        .environment(\.colorScheme, .light)
        .onAppear { model.beginDiscovery() }
        .onDisappear { model.endDiscovery() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ui(10)) {
            HStack(spacing: ui(10)) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: ui(26), height: ui(26))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ui(1)) {
                    Text("CrossDrop")
                        .font(ui.font(15, .bold))
                        .foregroundColor(CDPalette.textPrimary)
                    Text(ReceiverText.detail(model))
                        .font(ui.font(10.5))
                        .foregroundColor(CDPalette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ReceiveModePicker()
        }
        .padding(.horizontal, ui.m)
        .padding(.vertical, ui.m)
        .glassPanel(cornerRadius: CDRadius.card)
    }

    @ViewBuilder
    private var devices: some View {
        VStack(alignment: .leading, spacing: ui.s) {
            HStack(spacing: ui.s) {
                Text(sendTitle)
                    .font(ui.font(12.5, .semibold))
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.hasSomethingToSend {
                    Button("Clear") { model.clearSelection() }
                        .buttonStyle(GlassButtonStyle())
                }
            }
            if let text = model.pendingText {
                Label(text.text, systemImage: text.kind == .link ? "link" : "doc.plaintext")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if !model.networkAvailable {
                HStack(spacing: ui.m) {
                    DripView(pose: .nowifi, size: 56, motion: .still)
                    hint("Not connected to Wi-Fi. Join the same network as your phone.", symbol: "wifi.slash")
                }
            } else if model.discoveryStatus == .localNetworkDenied {
                hint("Allow Local Network access in System Settings › Privacy & Security.", symbol: "lock.shield")
            } else if model.nearby.isEmpty {
                HStack(spacing: ui.m) {
                    DripView(pose: .searching, size: 56, motion: .bob)
                    Text("Looking for nearby devices. Turn on Receiving on your phone.")
                        .font(ui.caption)
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
                        HStack(spacing: ui.s) {
                            DeviceAvatar(platform: device.platform, size: 28)
                            Text(device.name)
                                .font(ui.font(12.5, .medium))
                                .foregroundColor(CDPalette.textPrimary)
                                .lineLimit(1)
                            if model.isTrusted(device.deviceId) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(ui.system(10))
                                    .foregroundColor(CDPalette.mint)
                                    .accessibilityLabel("Paired")
                            }
                            if model.room(for: device) != nil && !model.isTrusted(device.deviceId) {
                                Image(systemName: "person.3.fill")
                                    .font(ui.system(9))
                                    .foregroundColor(CDPalette.sky)
                                    .accessibilityLabel("In your room")
                            }
                            let waiting = model.queuedSends(for: device.deviceId).count
                            if waiting > 0 {
                                Image(systemName: "clock.fill")
                                    .font(ui.system(9, .bold))
                                    .foregroundColor(CDPalette.amber)
                                    .accessibilityLabel(waiting == 1 ? "1 send waiting" : "\(waiting) sends waiting")
                            }
                            if device.isRemembered {
                                Text("not seen")
                                    .font(ui.font(10))
                                    .foregroundColor(CDPalette.textTertiary)
                                    .help("Not found nearby. CrossDrop will try the address that worked last time.")
                            }
                            Spacer(minLength: 0)
                            Image(systemName: model.hasSomethingToSend ? "paperplane.fill" : "plus")
                                .font(ui.system(11, .semibold))
                                .foregroundColor(model.hasSomethingToSend ? .white : CDPalette.ink)
                                .frame(width: ui(24), height: ui(24))
                                .background(Circle().fill(model.hasSomethingToSend ? CDPalette.ink : Color(hex: 0xE9F4EC)))
                        }
                        .padding(.horizontal, ui(10))
                        .padding(.vertical, ui(7))
                    }
                    .buttonStyle(TileButtonStyle())
                    .accessibilityLabel(model.hasSomethingToSend ? "Send to \(device.name)" : "Choose files for \(device.name)")
                    .help("Right-click for photos from the phone, the clipboard and Deliver When Nearby")
                    .contextMenu { DeviceActionsMenu(device: device).environmentObject(model) }
                }
            }
        }
        .padding(ui.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
    }

    private var sendTitle: String {
        if let text = model.pendingText { return text.kind == .link ? "Send link to" : "Send text to" }
        return model.selectedFiles.isEmpty ? "Nearby" : "Send \(Format.files(model.selectedFiles.count)) to"
    }

    private var footer: some View {
        HStack(spacing: ui.s) {
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
            Spacer(minLength: 0)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(GlassButtonStyle())
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func hint(_ text: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ui(6)) {
            Image(systemName: symbol).foregroundColor(CDPalette.textSecondary)
            Text(text)
                .font(ui.caption)
                .foregroundColor(CDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Drip Room in progress: name, a coarse countdown, Show Code (opens Devices) and End.
struct MenuBarRoomRow: View {
    let room: Room
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @State private var confirmEnd = false

    var body: some View {
        HStack(spacing: ui.s) {
            RoomEmblem(active: true, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(room.name)
                    .font(ui.font(12, .semibold))
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                TimelineView(.periodic(from: Date(), by: 15)) { context in
                    Text(RoomClock.short(room, now: context.date))
                        .font(ui.font(10.5).monospacedDigit())
                        .foregroundColor(CDPalette.textSecondary)
                        .lineLimit(1)
                        .accessibilityLabel(RoomClock.spoken(room, now: context.date))
                }
            }
            Spacer(minLength: 0)
            Button("Code") {
                model.selectedTab = .devices
                model.showingRoomSheet = true
                model.requestMainWindow()
            }
            .buttonStyle(GlassButtonStyle())
            .help("Show the room's QR code")
            .accessibilityLabel("Show room code")
            Button("End") { confirmEnd = true }
                .buttonStyle(GlassButtonStyle(destructive: true))
                .help("Ends the room now. Its members stop being trusted on this Mac.")
                .accessibilityLabel("End room \(room.name)")
        }
        .endRoomConfirmation(isPresented: $confirmEnd, room: room) { model.endRoom() }
        .padding(ui.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
        .accessibilityElement(children: .contain)
    }
}

/// My Devices / Everyone / Off, as the glass segmented control drawn at the UI scale,
/// filling the width it is given. `compact` is for tight spots such as the sidebar's
/// receiving pill.
struct ReceiveModePicker: View {
    var compact = false
    @EnvironmentObject private var model: AppModel

    private static let modes: [ReceiveMode] = Array(ReceiveMode.allCases)

    var body: some View {
        let modes = ReceiveModePicker.modes
        SegmentedGlass(choices: modes.indices.map { SegmentChoice(id: $0, label: modes[$0].title) },
                       selection: Binding(get: { modes.firstIndex(of: model.receiveMode) ?? 0 },
                                          set: { index in
                                              guard modes.indices.contains(index) else { return }
                                              model.setReceiveMode(modes[index])
                                          }),
                       accessibilityName: "Who can send to this Mac",
                       fillsWidth: true,
                       compact: compact)
            .help("My Devices: only devices you paired, invisible to others. Everyone: anyone nearby can ask to send.")
    }
}
