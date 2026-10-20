import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingForget: TrustedDeviceRecord?

    var body: some View {
        PageScroll {
            PageTitle(title: "Devices", subtitle: "Devices you've paired by confirming the same code on both screens.")
            ThisDeviceCard()
            SectionHeader(title: "Paired",
                          detail: model.trustedDevices.isEmpty ? nil : "\(model.trustedDevices.count)")
                .padding(.top, CDSpacing.s)
            if model.trustedDevices.isEmpty {
                StateMessage(symbol: "checkmark.shield",
                             title: "No paired devices yet",
                             message: "Send a file to a nearby device, or receive one, and confirm the 6-digit code on both screens. The device shows up here.",
                             pose: .pairing)
                    .glassPanel(cornerRadius: CDRadius.card)
            } else {
                ForEach(model.trustedDevices) { device in
                    TrustedDeviceRow(device: device, onForget: { pendingForget = device })
                }
            }
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
            Text("You'll confirm a pairing code again before exchanging files with this device.")
        }
    }
}

struct ThisDeviceCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: CDSpacing.l) {
            DeviceAvatar(platform: "macos", size: 50)
            VStack(alignment: .leading, spacing: 6) {
                Text("THIS MAC")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(CDPalette.textTertiary)
                Text(model.deviceName)
                    .font(CDFont.title)
                    .foregroundColor(CDPalette.textPrimary)
                Text(Format.fingerprint(model.identity.fingerprint))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(CDPalette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Fingerprint")
                    .accessibilityValue(model.identity.fingerprint)
                if model.identityLocation != .keychain {
                    Text(model.identityLocation == .file
                         ? "The identity key is stored in a protected file because the Keychain was unavailable."
                         : "The identity key couldn't be saved. Pairings will be lost when CrossDrop quits.")
                        .font(CDFont.caption)
                        .foregroundColor(CDPalette.amber)
                }
            }
            .legibleText()
            Spacer(minLength: 0)
        }
        .padding(CDSpacing.xl)
        .glassPanel(cornerRadius: CDRadius.panel)
    }
}

struct TrustedDeviceRow: View {
    @EnvironmentObject private var model: AppModel
    let device: TrustedDeviceRecord
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.m) {
            HStack(spacing: CDSpacing.m) {
                DeviceAvatar(platform: device.platform, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(CDFont.headline)
                        .foregroundColor(CDPalette.textPrimary)
                    Text(subtitle)
                        .font(CDFont.caption)
                        .foregroundColor(CDPalette.textSecondary)
                }
                Spacer(minLength: CDSpacing.s)
                Button("Forget…", action: onForget)
                    .buttonStyle(GlassButtonStyle(destructive: true))
                    .accessibilityLabel("Forget \(device.name)")
            }
            GlassDivider()
            Toggle(isOn: Binding(get: { device.autoAccept }, set: { model.setAutoAccept($0, for: device) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accept files automatically")
                        .font(CDFont.callout.weight(.medium))
                        .foregroundColor(CDPalette.textPrimary)
                    Text("Files from this device are saved without asking. They're still verified.")
                        .font(CDFont.caption)
                        .foregroundColor(CDPalette.textTertiary)
                }
            }
            .toggleStyle(GlassToggleStyle())
            Text(Format.fingerprint(device.fingerprint))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(CDPalette.textTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Fingerprint")
        }
        .padding(CDSpacing.l)
        .glassPanel(cornerRadius: CDRadius.card)
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
