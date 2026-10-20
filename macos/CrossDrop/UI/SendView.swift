import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct SendView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PageScroll {
            PageTitle(title: "Send", subtitle: "Drop files, pick a nearby device. Straight there, encrypted, no cloud.")
            DropZone()
            if !model.selectedFiles.isEmpty {
                SelectedFilesCard()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            NearbyCard()
            let outgoing = model.outgoingTransfers
            if !outgoing.isEmpty {
                SectionHeader(title: "Transfers", detail: "This session")
                    .padding(.top, CDSpacing.s)
                ForEach(outgoing) { item in
                    TransferCard(item: item)
                }
            }
        }
        .animation(CDMotion.layout(reduceMotion), value: model.selectedFiles)
    }
}

// MARK: - Drop zone

struct DropZone: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    @State private var targeted = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let radius = compact ? CDRadius.card : CDRadius.panel
        let lit = targeted || hovering
        VStack(spacing: compact ? CDSpacing.s : CDSpacing.m) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(targeted ? 0.3 : 0.16))
                Circle()
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                Image(systemName: targeted ? "arrow.down" : "arrow.down.doc")
                    .font(.system(size: compact ? 17 : 26, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: compact ? 40 : 68, height: compact ? 40 : 68)
            .shadow(color: Color.white.opacity(targeted ? 0.45 : 0.12), radius: targeted ? 22 : 10)
            .scaleEffect(targeted && !reduceMotion ? 1.08 : 1)
            .accessibilityHidden(true)

            Text(targeted ? "Release to add" : "Drop files to send")
                .font(compact ? Font.system(size: 14, weight: .semibold, design: .rounded) : CDFont.title)
                .foregroundColor(.white)
                .legibleText()

            if !compact {
                Text("Drag from Finder, or choose them. Folders aren't supported yet.")
                    .font(CDFont.callout)
                    .foregroundColor(CDPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: CDSpacing.s) {
                Button {
                    model.chooseFiles()
                } label: {
                    Label("Choose Files…", systemImage: "plus")
                }
                .buttonStyle(GlassButtonStyle())
                .help("Choose files to send (⌘O)")
                if !model.selectedFiles.isEmpty && !compact {
                    Chip(text: Format.files(model.selectedFiles.count), symbol: "doc.on.doc")
                    Chip(text: Format.bytes(model.selectedTotalBytes))
                }
            }
            .padding(.top, compact ? 0 : 4)
        }
        .padding(compact ? CDSpacing.l : 36)
        .frame(maxWidth: .infinity, minHeight: compact ? 140 : 250)
        .glassPanel(cornerRadius: radius)
        .overlay(
            RoundedRectangle(cornerRadius: radius - 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1.25, lineCap: .round,
                                                 dash: targeted ? [] : [6, 7]))
                .foregroundColor(Color.white.opacity(targeted ? 0.85 : (lit ? 0.5 : 0.3)))
                .padding(10)
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

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.m) {
            HStack {
                SectionHeader(title: "Ready to send",
                              detail: "\(Format.files(model.selectedFiles.count)) · \(Format.bytes(model.selectedTotalBytes))")
                Button("Clear All") { model.clearSelection() }
                    .buttonStyle(GlassButtonStyle())
            }
            VStack(spacing: 0) {
                ForEach(model.selectedFiles) { file in
                    HStack(spacing: CDSpacing.m) {
                        FileIcon(url: file.url, name: file.name, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(CDFont.body)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Format.bytes(file.size))
                                .font(CDFont.caption.monospacedDigit())
                                .foregroundColor(CDPalette.textTertiary)
                        }
                        Spacer(minLength: CDSpacing.s)
                        Button {
                            model.removeFile(file)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .accessibilityLabel("Remove \(file.name)")
                    }
                    .padding(.vertical, 8)
                    if file.id != model.selectedFiles.last?.id {
                        GlassDivider().padding(.leading, 42)
                    }
                }
            }
        }
        .padding(CDSpacing.l)
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

// MARK: - Nearby

struct NearbyCard: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: CDSpacing.m)]

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.l) {
            HStack {
                SectionHeader(title: "Nearby", detail: headerDetail)
                if model.discoveryStatus == .browsing && !model.nearby.isEmpty {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                        .accessibilityLabel("Still looking")
                }
            }
            stateContent
        }
        .padding(CDSpacing.l)
        .glassPanel(cornerRadius: CDRadius.card)
    }

    private var headerDetail: String? {
        if model.nearby.isEmpty { return model.discoveryStatus == .browsing ? "Looking…" : nil }
        return model.selectedFiles.isEmpty ? "Add files, then click a device" : "Click a device to send"
    }

    @ViewBuilder
    private var stateContent: some View {
        if !model.networkAvailable {
            StateMessage(symbol: "wifi.slash", title: "Not connected to a network",
                         message: "Connect this Mac to the same Wi-Fi network as your Android phone.",
                         tint: CDPalette.coral)
        } else if model.discoveryStatus == .localNetworkDenied {
            VStack(spacing: CDSpacing.s) {
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
            HStack(spacing: CDSpacing.xl) {
                RadarView(active: model.discoveryStatus == .browsing)
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Looking for nearby devices")
                        .font(CDFont.headline)
                        .foregroundColor(.white)
                    Text("Open CrossDrop on your phone and turn on Receiving. Both devices need the same Wi-Fi; guest networks often keep devices from seeing each other.")
                        .font(CDFont.callout)
                        .foregroundColor(CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .legibleText()
            }
            .padding(.vertical, CDSpacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: CDSpacing.m) {
                ForEach(model.nearby) { device in
                    DeviceTile(device: device,
                               trusted: model.isTrusted(device.deviceId),
                               canSend: !model.selectedFiles.isEmpty) {
                        if model.selectedFiles.isEmpty {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CDSpacing.m) {
                DeviceAvatar(platform: device.platform, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: trusted ? "checkmark.seal.fill" : "sparkles")
                            .font(.system(size: 9, weight: .bold))
                        Text(trusted ? "Paired" : "New · pair first")
                    }
                    .font(CDFont.caption)
                    .foregroundColor(trusted ? CDPalette.mint : CDPalette.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: canSend ? "paperplane.fill" : "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(canSend ? Color.black.opacity(0.8) : .white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(canSend ? Color.white : Color.white.opacity(0.14)))
            }
            .padding(12)
        }
        .buttonStyle(TileButtonStyle())
        .accessibilityLabel("\(device.name), \(device.platform == "android" ? "Android" : "Mac"), \(trusted ? "paired" : "not paired")")
        .accessibilityHint(canSend ? "Sends the selected files" : "Choose files to send to this device")
    }
}

/// Inset glass tile that lifts slightly on hover.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            configuration.label
                .background(shape.fill(Color.white.opacity(configuration.isPressed ? 0.2 : (hovering ? 0.15 : 0.09))))
                .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.45 : 0.22), lineWidth: 1))
                .contentShape(shape)
                .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
                .animation(reduceMotion ? nil : CDMotion.quick, value: hovering)
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: shape))
        }
    }
}
