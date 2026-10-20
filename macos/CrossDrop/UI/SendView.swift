import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct SendView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CDSpacing.xl) {
                DropZone()
                if !model.selectedFiles.isEmpty {
                    SelectedFilesCard()
                }
                NearbyCard()
                if !model.activeTransfers.isEmpty {
                    VStack(alignment: .leading, spacing: CDSpacing.m) {
                        SectionHeader(title: "In progress")
                        ForEach(model.activeTransfers) { item in
                            TransferCard(item: item)
                        }
                    }
                }
            }
            .padding(CDSpacing.xl)
        }
    }
}

struct DropZone: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CDRadius.large, style: .continuous)
        VStack(spacing: compact ? CDSpacing.s : CDSpacing.m) {
            ZStack {
                Circle()
                    .fill(CDPalette.brand)
                    .opacity(targeted ? 1 : 0.9)
                Circle()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
                Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.down.doc.fill")
                    .font(.system(size: compact ? 18 : 26, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: compact ? 40 : 64, height: compact ? 40 : 64)
            .shadow(color: CDPalette.sky.opacity(targeted ? 0.55 : 0.25), radius: targeted ? 18 : 10, x: 0, y: 6)
            .accessibilityHidden(true)

            Text(targeted ? "Release to add" : "Drop files here")
                .font(.system(size: compact ? 14 : 19, weight: .semibold, design: .rounded))
            if !compact {
                Text("Drag files from Finder, or choose them. They stay on this Mac until you pick a device.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: CDSpacing.s) {
                Button("Choose Files…") { model.chooseFiles() }
                    .buttonStyle(GlassButtonStyle())
                    .help("Choose files to send (⌘O)")
                if !compact {
                    Text("Folders aren't supported yet")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(compact ? CDSpacing.l : CDSpacing.xxl)
        .frame(maxWidth: .infinity, minHeight: compact ? 130 : 230)
        .cdGlass(radius: CDRadius.large)
        .overlay(
            shape
                .strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1.25, dash: targeted ? [] : [7, 6]))
                .foregroundColor(targeted ? Color.accentColor : Color.secondary.opacity(0.45))
                .padding(6)
                .allowsHitTesting(false)
        )
        .scaleEffect(targeted && !reduceMotion ? 1.012 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: targeted)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            model.addDroppedItems(providers)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drop zone")
        .accessibilityHint("Drop files here to send them, or use Choose Files.")
    }
}

struct SelectedFilesCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.m) {
            HStack {
                SectionHeader(title: "Ready to send",
                              detail: "\(Format.files(model.selectedFiles.count)) · \(Format.bytes(model.selectedTotalBytes))")
                Button("Clear") { model.clearSelection() }
                    .buttonStyle(GlassButtonStyle())
            }
            VStack(spacing: 0) {
                ForEach(model.selectedFiles) { file in
                    HStack(spacing: CDSpacing.m) {
                        FileIcon(url: file.url, name: file.name, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Text(Format.bytes(file.size)).font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            model.removeFile(file)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(IconButtonStyle())
                        .accessibilityLabel("Remove \(file.name)")
                    }
                    .padding(.vertical, 6)
                    if file.id != model.selectedFiles.last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .padding(CDSpacing.l)
        .cdGlass(radius: CDRadius.medium)
    }
}

struct NearbyCard: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: CDSpacing.m)]

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.l) {
            SectionHeader(title: "Nearby devices", detail: headerDetail)
            stateContent
            if !model.nearby.isEmpty {
                sendBar
            }
        }
        .padding(CDSpacing.l)
        .cdGlass(radius: CDRadius.medium)
    }

    private var headerDetail: String? {
        switch model.discoveryStatus {
        case .browsing: return model.nearby.isEmpty ? "Looking…" : nil
        default: return nil
        }
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
        } else if case .failed(let message) = model.discoveryStatus {
            StateMessage(symbol: "exclamationmark.triangle", title: "Can't look for devices", message: message,
                         tint: CDPalette.coral)
        } else if model.nearby.isEmpty {
            HStack(spacing: CDSpacing.xl) {
                RadarView(active: model.discoveryStatus == .browsing)
                    .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: CDSpacing.s) {
                    Text("Looking for nearby devices…").font(.system(size: 14, weight: .semibold))
                    Text("Open CrossDrop on your Android phone and turn on Receiving. Both devices must be on the same Wi-Fi. Guest networks and some office networks block devices from seeing each other.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: CDSpacing.m) {
                ForEach(model.nearby) { device in
                    DeviceTile(device: device,
                               trusted: model.isTrusted(device.deviceId),
                               selected: model.selectedDeviceId == device.deviceId) {
                        model.selectedDeviceId = device.deviceId
                    }
                }
            }
        }
    }

    private var sendBar: some View {
        HStack(spacing: CDSpacing.m) {
            Text(sendHint)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                if let device = model.selectedDevice { model.sendSelection(to: device) }
            } label: {
                Label("Send", systemImage: "paperplane.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectedFiles.isEmpty || model.selectedDevice == nil)
        }
    }

    private var sendHint: String {
        if model.selectedFiles.isEmpty { return "Add files above, then choose a device." }
        guard let device = model.selectedDevice else { return "Choose a device to send to." }
        let what = "\(Format.files(model.selectedFiles.count)) (\(Format.bytes(model.selectedTotalBytes)))"
        if model.isTrusted(device.deviceId) {
            return "Send \(what) to \(device.name)."
        }
        return "Send \(what) to \(device.name). You'll confirm a pairing code on both devices first."
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
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: CDSpacing.s) {
                DeviceAvatar(platform: device.platform, size: 48)
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 4) {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "seal")
                    Text(trusted ? "Paired" : "Not paired yet")
                }
                .font(.system(size: 11))
                .foregroundColor(trusted ? CDPalette.mint : .secondary)
            }
            .padding(CDSpacing.m)
            .frame(maxWidth: .infinity, minHeight: 128)
            .background(
                RoundedRectangle(cornerRadius: CDRadius.medium, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: CDRadius.medium, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.25), lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: CDRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(device.name), \(device.platform == "android" ? "Android" : "Mac"), \(trusted ? "paired" : "not paired")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Selects this device as the destination.")
    }
}

/// Discovery animation; static rings when Reduce Motion is on or when idle.
struct RadarView: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            let phase = (time / 2.4 + Double(index) / 3.0).truncatingRemainder(dividingBy: 1.0)
                            Circle()
                                .stroke(CDPalette.sky.opacity(0.55 * (1 - phase)), lineWidth: 1.5)
                                .scaleEffect(0.35 + phase * 0.65)
                        }
                    }
                }
            } else {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(CDPalette.sky.opacity(0.18 + Double(index) * 0.06), lineWidth: 1)
                        .scaleEffect(0.45 + Double(index) * 0.25)
                }
            }
            ZStack {
                Circle().fill(CDPalette.brand)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 44, height: 44)
        }
        .accessibilityHidden(true)
    }
}
