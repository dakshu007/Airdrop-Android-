import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingForget: TrustedDeviceRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CDSpacing.xl) {
                ThisDeviceCard()
                VStack(alignment: .leading, spacing: CDSpacing.m) {
                    SectionHeader(title: "Paired devices",
                                  detail: model.trustedDevices.isEmpty ? nil : "\(model.trustedDevices.count)")
                    if model.trustedDevices.isEmpty {
                        StateMessage(symbol: "checkmark.shield",
                                     title: "No paired devices yet",
                                     message: "A device appears here after you both confirm the same six-digit code. Paired devices can send to you without pairing again; you still approve each transfer unless you allow automatic acceptance.")
                            .cdGlass(radius: CDRadius.medium)
                    } else {
                        ForEach(model.trustedDevices) { device in
                            TrustedDeviceRow(device: device, onForget: { pendingForget = device })
                        }
                    }
                }
            }
            .padding(CDSpacing.xl)
        }
        .confirmationDialog(
            "Forget \(pendingForget?.name ?? "this device")?",
            isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }),
            titleVisibility: .visible,
            presenting: pendingForget
        ) { device in
            Button("Forget Device", role: .destructive) { model.forget(device) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You'll need to confirm a pairing code again before exchanging files with this device.")
        }
    }
}

struct ThisDeviceCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: CDSpacing.l) {
            DeviceAvatar(platform: "macos", size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                Text(model.deviceName).font(.system(size: 16, weight: .semibold))
                Text("Fingerprint").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 4)
                Text(Format.fingerprint(model.identity.fingerprint))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Fingerprint")
                    .accessibilityValue(model.identity.fingerprint)
                if model.identityLocation != .keychain {
                    Text(model.identityLocation == .file
                         ? "The identity key is stored in a protected file because the Keychain was unavailable."
                         : "The identity key couldn't be saved. Pairings will be lost when CrossDrop quits.")
                        .font(.system(size: 11))
                        .foregroundColor(CDPalette.amber)
                }
            }
            Spacer()
        }
        .padding(CDSpacing.l)
        .cdGlass(radius: CDRadius.medium)
    }
}

struct TrustedDeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let device: TrustedDeviceRecord
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.m) {
            HStack(spacing: CDSpacing.m) {
                DeviceAvatar(platform: device.platform, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Forget…", action: onForget)
                    .buttonStyle(GlassButtonStyle(destructive: true))
                    .accessibilityLabel("Forget \(device.name)")
            }
            Toggle(isOn: Binding(get: { device.autoAccept }, set: { model.setAutoAccept($0, for: device) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accept files automatically").font(.system(size: 12, weight: .medium))
                    Text("Files from this device are saved without asking. They're still verified.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(Format.fingerprint(device.fingerprint))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Fingerprint")
        }
        .padding(CDSpacing.l)
        .cdGlass(radius: CDRadius.medium)
    }

    private var subtitle: String {
        let platform = device.platform == "android" ? "Android" : "Mac"
        let paired = "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"
        if let used = device.lastUsedAt {
            return "\(platform) · \(paired) · Last used \(used.formatted(.relative(presentation: .named)))"
        }
        return "\(platform) · \(paired)"
    }
}
