import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct SendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui

    var body: some View {
        PageScroll(allowsWide: true) {
            PageTitle(title: "Send to your phone",
                      subtitle: "Drop files below, then pick a device. Files never leave your Wi-Fi.",
                      trailing: AnyView(StatusPill(text: nearbyText, dot: model.nearby.isEmpty ? Color(hex: 0x9AA8A0) : CDPalette.mint)))
            if ui.wide {
                // Wide windows: what you're sending on the left, where it goes on the right.
                TwoColumns {
                    sendables
                } trailing: {
                    destinations
                }
            } else {
                sendables
                destinations
            }
        }
        .animation(CDMotion.layout(reduceMotion), value: model.selectedFiles)
        .animation(CDMotion.layout(reduceMotion), value: model.pendingText)
    }

    @ViewBuilder
    private var sendables: some View {
        DropZone()
        if !model.selectedFiles.isEmpty {
            SelectedFilesCard()
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
        if let text = model.pendingText {
            PendingTextCard(text: text)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var destinations: some View {
        NearbyCard()
        let outgoing = model.outgoingTransfers
        if !outgoing.isEmpty {
            SectionHeader(title: "Transfers", detail: "This session")
                .padding(.top, ui.s)
            ForEach(outgoing) { item in
                TransferCard(item: item)
            }
        }
    }

    private var nearbyText: String {
        switch model.nearby.count {
        case 0: return "Looking nearby"
        case 1: return "1 device nearby"
        default: return "\(model.nearby.count) devices nearby"
        }
    }
}

// MARK: - Drop zone

struct DropZone: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    @State private var targeted = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui

    var body: some View {
        let radius: CGFloat = compact ? CDRadius.card : CDRadius.panel
        let dashInset: CGFloat = compact ? 8 : 12
        let lit = targeted || hovering
        VStack(spacing: compact ? ui.s : ui.m) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0xBEF5AA, opacity: targeted ? 0.8 : 0.55), Color(hex: 0xBEF5AA, opacity: 0)],
                                         center: .center, startRadius: 0, endRadius: ui(compact ? 50 : 120)))
                    .frame(width: ui(compact ? 100 : 230), height: ui(compact ? 100 : 230))
                DripView(pose: targeted ? .incoming : .mac, size: compact ? 84 : 210, motion: .bob)
            }
            .frame(height: ui(compact ? 70 : 170))
            .scaleEffect(targeted && !reduceMotion ? 1.06 : 1)
            .accessibilityHidden(true)

            Text(targeted ? "Release to add" : (compact ? "Drop files to send" : "Drop files here"))
                .font(compact ? ui.font(14, .semibold) : ui.font(22, .bold))
                .foregroundColor(CDPalette.textPrimary)
                .multilineTextAlignment(.center)

            if !compact {
                Text("Drag from Finder or onto the menu bar icon. Folders keep their structure.")
                    .font(ui.callout)
                    .foregroundColor(CDPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: ui.s) {
                Button {
                    model.chooseFiles()
                } label: {
                    HStack(spacing: ui(8)) {
                        Text("Choose Files…")
                        if !compact {
                            Text("⌘O").foregroundColor(Color(hex: 0xA8B8AE))
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle(large: !compact))
                .help("Choose files or folders to send (⌘O)")
                if !compact {
                    Button {
                        model.takeClipboard()
                    } label: {
                        Label("Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Send the link or text you copied (⇧⌘V). A link opens on the phone.")
                }
                if !model.selectedFiles.isEmpty && !compact {
                    Chip(text: Format.files(model.selectedFiles.count), symbol: "doc.on.doc")
                    Chip(text: Format.bytes(model.selectedTotalBytes))
                }
            }
            .padding(.top, compact ? 0 : ui(4))
        }
        .padding(compact ? ui.l : ui(30))
        .frame(maxWidth: .infinity, minHeight: ui(compact ? 140 : 300))
        .glassPanel(cornerRadius: radius)
        .overlay(
            RoundedRectangle(cornerRadius: ui(radius - dashInset), style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: ui(2), lineCap: .round,
                                                 dash: targeted ? [] : [ui(7), ui(7)]))
                .foregroundColor(CDPalette.mint.opacity(targeted ? 0.8 : (lit ? 0.45 : 0.28)))
                .padding(ui(dashInset))
                .allowsHitTesting(false)
        )
        .scaleEffect(targeted && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : CDMotion.quick, value: targeted)
        .animation(.easeOut(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            model.addDroppedItems(providers)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone")
        .accessibilityHint("Drop files here to send them, or use Choose Files.")
    }
}

// MARK: - Selected files

struct SelectedFilesCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: ui(6)) {
            HStack(spacing: ui.s) {
                SectionHeader(title: "Ready to send",
                              detail: "\(Format.files(model.selectedFiles.count)) · \(Format.bytes(model.selectedTotalBytes))")
                Button("Clear All") { model.clearSelection() }
                    .buttonStyle(GlassButtonStyle())
            }
            VStack(spacing: 0) {
                ForEach(model.selectedFiles) { file in
                    HStack(spacing: ui.m) {
                        FileIcon(url: file.url, name: file.name, size: 30)
                        VStack(alignment: .leading, spacing: ui(2)) {
                            Text(file.displayName)
                                .font(ui.body)
                                .foregroundColor(CDPalette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Format.bytes(file.size))
                                .font(ui.caption.monospacedDigit())
                                .foregroundColor(CDPalette.textTertiary)
                        }
                        Spacer(minLength: ui.s)
                        Button {
                            model.removeFile(file)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .accessibilityLabel("Remove \(file.displayName)")
                    }
                    .padding(.vertical, ui(10))
                    if file.id != model.selectedFiles.last?.id {
                        // Starts under the file name, so the icons read as one column.
                        GlassDivider().padding(.leading, ui(30) + ui.m)
                    }
                }
            }
        }
        .padding(.horizontal, ui(CDLayout.cardPadding))
        .padding(.top, ui(CDLayout.cardPadding - 2))
        .padding(.bottom, ui(CDLayout.cardPadding - 10))
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

/// A link or text from the clipboard, waiting to be sent (§9.2).
struct PendingTextCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    let text: PendingText

    var body: some View {
        VStack(alignment: .leading, spacing: ui.m) {
            HStack(spacing: ui.s) {
                SectionHeader(title: text.kind == .link ? "Link ready to send" : "Text ready to send",
                              detail: text.kind == .link ? "Opens on the phone when it arrives" : "Lands on the phone's clipboard, not as a file")
                Button("Clear") { model.pendingText = nil }
                    .buttonStyle(GlassButtonStyle())
            }
            HStack(alignment: .top, spacing: ui.m) {
                Image(systemName: text.kind == .link ? "link" : "doc.plaintext")
                    .font(ui.system(18, .medium))
                    .foregroundColor(CDPalette.mint)
                    .frame(width: ui(30))
                Text(text.text)
                    .font(ui.body)
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(text.kind == .link ? 2 : 5)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(ui.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: CDRadius.tile, style: .inset)
        }
        .padding(ui(CDLayout.cardPadding))
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

// MARK: - Nearby

struct NearbyCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    private var columns: [GridItem] {
        // No maximum, so a lone column fills the card; two columns only once each tile
        // has room for the name, its status and the Send pill.
        [GridItem(.adaptive(minimum: ui(320)), spacing: ui.m, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ui.l) {
            HStack(spacing: ui.s) {
                SectionHeader(title: "Nearby", detail: headerDetail)
                if model.discoveryStatus == .browsing && !model.nearby.isEmpty {
                    // Native spinners don't follow the UI scale, so scale the drawing.
                    ProgressView().controlSize(.small).scaleEffect(0.8 * ui.factor)
                        .frame(width: ui(16), height: ui(16))
                        .accessibilityLabel("Still looking")
                }
                if model.nearby.count > 1 && model.hasSomethingToSend {
                    Button(model.multiSelecting ? "Cancel" : "Send to Several…") {
                        model.multiSelecting.toggle()
                        model.multiSelection.removeAll()
                    }
                    .buttonStyle(GlassButtonStyle())
                }
            }
            stateContent
            if model.multiSelecting {
                let chosen = model.nearby.filter { model.multiSelection.contains($0.deviceId) }
                HStack(spacing: ui.m) {
                    Text(chosen.isEmpty ? "Tick the devices to send to." : "Each device gets its own verified copy.")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(chosen.count > 1 ? "Send to \(chosen.count) Devices" : "Send") {
                        model.sendSelection(to: chosen)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
    }

    private var headerDetail: String? {
        if model.nearby.isEmpty { return model.discoveryStatus == .browsing ? "Looking…" : nil }
        return model.hasSomethingToSend ? "Click a device to send" : "Add files, then click a device"
    }

    @ViewBuilder
    private var stateContent: some View {
        if !model.networkAvailable {
            StateMessage(symbol: "wifi.slash", title: "No Wi-Fi",
                         message: "Connect this Mac to the same Wi-Fi network as your Android phone.",
                         tint: CDPalette.coral, pose: .nowifi)
        } else if model.discoveryStatus == .localNetworkDenied {
            VStack(spacing: ui.s) {
                StateMessage(symbol: "lock.shield", title: "Local Network access is off",
                             message: "CrossDrop needs Local Network access to find nearby devices. Turn it on in System Settings › Privacy & Security › Local Network.",
                             tint: CDPalette.amber)
                Button("Open System Settings") { openLocalNetworkSettings() }
                    .buttonStyle(GlassButtonStyle())
            }
            .frame(maxWidth: .infinity)
        } else if case .failed(let message) = model.discoveryStatus {
            StateMessage(symbol: "exclamationmark.triangle", title: "Can't look for devices", message: message,
                         tint: CDPalette.coral)
        } else if model.nearby.isEmpty {
            HStack(spacing: ui.xl) {
                ZStack {
                    RadarView(active: model.discoveryStatus == .browsing)
                        .frame(width: ui(130), height: ui(130))
                    DripView(pose: .searching, size: 120, motion: .bob)
                }
                .frame(width: ui(130), height: ui(130))
                VStack(alignment: .leading, spacing: ui(6)) {
                    Text("Drip is still looking")
                        .font(ui.headline)
                        .foregroundColor(CDPalette.textPrimary)
                    Text("Open CrossDrop on your phone and turn on Receiving. Both devices need the same Wi-Fi; guest networks often keep devices from seeing each other.")
                        .font(ui.callout)
                        .foregroundColor(CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .legibleText()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, ui.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: ui.m) {
                ForEach(model.nearby) { device in
                    DeviceTile(device: device,
                               trusted: model.isTrusted(device.deviceId),
                               canSend: model.hasSomethingToSend,
                               ticked: model.multiSelecting ? model.multiSelection.contains(device.deviceId) : nil) {
                        if model.multiSelecting {
                            if model.multiSelection.contains(device.deviceId) {
                                model.multiSelection.remove(device.deviceId)
                            } else {
                                model.multiSelection.insert(device.deviceId)
                            }
                        } else if !model.hasSomethingToSend {
                            model.selectedDeviceId = device.deviceId
                            model.chooseFiles()
                        } else {
                            model.sendSelection(to: device)
                        }
                    }
                }
            }
        }
    }

    private func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct DeviceTile: View {
    let device: DiscoveredDevice
    let trusted: Bool
    let canSend: Bool
    /// Non-nil while choosing several devices: whether this one is ticked.
    var ticked: Bool? = nil
    let action: () -> Void
    @Environment(\.cdScale) private var ui

    var body: some View {
        Button(action: action) {
            HStack(spacing: ui.m) {
                DeviceAvatar(platform: device.platform, size: 42)
                VStack(alignment: .leading, spacing: ui(4)) {
                    Text(device.name)
                        .font(ui.font(13.5, .semibold))
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: ui(5)) {
                        if trusted && !device.isRemembered {
                            Circle().fill(CDPalette.mint).frame(width: ui(6), height: ui(6))
                        }
                        Text(device.isRemembered ? "Paired · not seen nearby" : (trusted ? "Paired" : "New · confirm a code"))
                            .lineLimit(1)
                    }
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textSecondary)
                }
                Spacer(minLength: 0)
                if let ticked = ticked {
                    Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                        .font(ui.system(22))
                        .foregroundColor(ticked ? CDPalette.mint : CDPalette.textTertiary)
                } else {
                    Text(canSend ? (trusted ? "Send" : "Pair & Send") : "Choose…")
                        .font(ui.font(12.5, .semibold))
                        .foregroundColor(canSend ? .white : CDPalette.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, ui(14))
                        .frame(height: ui(30))
                        .background(Capsule().fill(canSend ? CDPalette.ink : Color(hex: 0xE9F4EC)))
                }
            }
            .padding(ui(12))
        }
        .buttonStyle(TileButtonStyle())
        .help(device.isRemembered ? "Not found nearby. CrossDrop will try the address that worked last time." : "")
        .accessibilityLabel("\(device.name), \(device.platform == "android" ? "Android" : "Mac"), \(trusted ? "paired" : "not paired")\(ticked == true ? ", selected" : "")")
        .accessibilityHint(canSend ? "Sends the selected files" : "Choose files to send to this device")
    }
}
