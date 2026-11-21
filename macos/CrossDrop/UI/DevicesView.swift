import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct DevicesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @State private var pendingForget: TrustedDeviceRecord?

    var body: some View {
        PageScroll(allowsWide: true) {
            PageTitle(title: "Devices", subtitle: "Devices you've paired by confirming the same code on both screens.")
            if ui.wide {
                HStack(alignment: .top, spacing: ui(CDLayout.cardGap)) {
                    ThisDeviceCard()
                    PairPhoneCard()
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ThisDeviceCard()
                PairPhoneCard()
            }
            SectionHeader(title: "Paired",
                          detail: model.trustedDevices.isEmpty ? nil : "\(model.trustedDevices.count)")
                .padding(.top, ui.s)
            if model.trustedDevices.isEmpty {
                StateMessage(symbol: "checkmark.shield",
                             title: "No paired devices yet",
                             message: "Send a file to a nearby device, or receive one, and confirm the 6-digit code on both screens. The device shows up here.",
                             pose: .pairing)
                    .glassPanel(cornerRadius: CDRadius.card)
            } else if ui.wide {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: ui(CDLayout.cardGap), alignment: .top),
                                    GridItem(.flexible(), spacing: ui(CDLayout.cardGap), alignment: .top)],
                          alignment: .leading, spacing: ui(CDLayout.cardGap)) {
                    ForEach(model.trustedDevices) { device in
                        TrustedDeviceRow(device: device, onForget: { pendingForget = device })
                    }
                }
            } else {
                ForEach(model.trustedDevices) { device in
                    TrustedDeviceRow(device: device, onForget: { pendingForget = device })
                }
            }
        }
        .sheet(isPresented: $model.showingPairSheet) {
            PairPhoneSheet()
                .environmentObject(model)
                .environment(\.cdScale, ui.fitting(height: 660))
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

/// Entry point for QR pairing: no numbers to compare, works where discovery is blocked.
struct PairPhoneCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    var body: some View {
        HStack(spacing: ui.l) {
            Image(systemName: "qrcode")
                .font(ui.system(26, .medium))
                .foregroundColor(CDPalette.ink)
                .frame(width: ui(50), height: ui(50))
                .background(Circle().fill(Color(hex: 0xE9F4EC)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ui(4)) {
                Text("Pair a phone with a QR code")
                    .font(ui.headline)
                    .foregroundColor(CDPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Scan it with CrossDrop on your phone. Nothing to compare, and it works even on networks where devices can't see each other.")
                    .font(ui.callout)
                    .foregroundColor(CDPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Show Code") { model.showingPairSheet = true }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

struct ThisDeviceCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    var body: some View {
        HStack(alignment: .top, spacing: ui.l) {
            DeviceAvatar(platform: "macos", size: 50)
            VStack(alignment: .leading, spacing: ui(6)) {
                Text("THIS MAC")
                    .font(ui.system(10, .semibold))
                    .tracking(0.8)
                    .foregroundColor(CDPalette.textTertiary)
                Text(model.deviceName)
                    .font(ui.title)
                    .foregroundColor(CDPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Format.fingerprint(model.identity.fingerprint))
                    .font(ui.system(11, design: .monospaced))
                    .foregroundColor(CDPalette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Fingerprint")
                    .accessibilityValue(model.identity.fingerprint)
                if model.identityLocation != .keychain {
                    Text(model.identityLocation == .file
                         ? "The identity key is stored in a protected file because the Keychain was unavailable."
                         : "The identity key couldn't be saved. Pairings will be lost when CrossDrop quits.")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .legibleText()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

struct TrustedDeviceRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    let device: TrustedDeviceRecord
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ui.m) {
                DeviceAvatar(platform: device.platform, size: 42)
                VStack(alignment: .leading, spacing: ui(3)) {
                    Text(device.name)
                        .font(ui.headline)
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Forget…", action: onForget)
                    .buttonStyle(GlassButtonStyle(destructive: true))
                    .accessibilityLabel("Forget \(device.name)")
            }
            .padding(.bottom, ui(CDLayout.rowPadding))
            GlassDivider()
            SettingsRow {
                VStack(alignment: .leading, spacing: ui.s) {
                    Toggle(isOn: Binding(get: { device.autoAccept }, set: { model.setAutoAccept($0, for: device) })) {
                        VStack(alignment: .leading, spacing: ui(2)) {
                            Text("Accept files automatically")
                                .font(ui.font(12, .medium))
                                .foregroundColor(CDPalette.textPrimary)
                            Text("Files from this device are saved without asking. They're still verified.")
                                .font(ui.caption)
                                .foregroundColor(CDPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(GlassToggleStyle())
                    Text(Format.fingerprint(device.fingerprint))
                        .font(ui.system(10, design: .monospaced))
                        .foregroundColor(CDPalette.textTertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Fingerprint")
                }
            }
        }
        .padding(.horizontal, ui(CDLayout.cardPadding))
        .padding(.top, ui(CDLayout.cardPadding))
        .padding(.bottom, ui(CDLayout.cardPadding - CDLayout.rowPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
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
