import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var nameDraft = ""

    private struct AutoOffChoice: Identifiable {
        let minutes: Int
        let label: String
        var id: Int { minutes }
    }

    private let autoOffChoices = [
        AutoOffChoice(minutes: 0, label: "Never"),
        AutoOffChoice(minutes: 10, label: "10 min"),
        AutoOffChoice(minutes: 30, label: "30 min"),
        AutoOffChoice(minutes: 60, label: "1 hour"),
    ]

    var body: some View {
        PageScroll {
            PageTitle(title: "Settings", subtitle: "Everything here stays on this Mac.")

            SettingsSection(title: "This Mac", symbol: "laptopcomputer") {
                Text("Name shown to nearby devices")
                    .font(CDFont.caption)
                    .foregroundColor(CDPalette.textTertiary)
                HStack(spacing: CDSpacing.s) {
                    TextField("Device name", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(CDFont.body)
                        .foregroundColor(CDPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .glassPanel(cornerRadius: 10, style: .inset)
                        .onSubmit { model.rename(nameDraft) }
                        .accessibilityLabel("Device name")
                    Button("Save") { model.rename(nameDraft) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || nameDraft == model.deviceName)
                }
            }

            SettingsSection(title: "Receiving", symbol: "antenna.radiowaves.left.and.right") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Who can send to this Mac")
                            .font(CDFont.body)
                            .foregroundColor(CDPalette.textPrimary)
                        Text("My Devices: only devices you paired, and this Mac stays invisible to others.")
                            .font(CDFont.caption)
                            .foregroundColor(CDPalette.textTertiary)
                    }
                    Spacer()
                    ReceiveModePicker()
                        .frame(width: 280)
                }
                GlassDivider()
                HStack {
                    Text("Everyone: back to My Devices after")
                        .font(CDFont.body)
                        .foregroundColor(CDPalette.textPrimary)
                    Spacer()
                    SegmentedGlass(choices: autoOffChoices.map { SegmentChoice(id: $0.minutes, label: $0.label) },
                                   selection: Binding(get: { model.autoOffMinutes },
                                                      set: { model.setAutoOff(minutes: $0) }))
                }
                Text("With Everyone, this Mac announces its name and device ID on the local network; with My Devices, a random name instead. Every connection still proves its identity, and new devices must pair first.")
                    .font(CDFont.caption)
                    .foregroundColor(CDPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: "Photos", symbol: "photo") {
                Toggle(isOn: Binding(get: { model.heicToJpeg }, set: { model.setHeicToJpeg($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also save HEIC photos as JPEG")
                            .font(CDFont.body)
                            .foregroundColor(CDPalette.textPrimary)
                        Text("Phones send photos in original quality. This adds a JPEG copy for apps that can't open HEIC; the original is kept.")
                            .font(CDFont.caption)
                            .foregroundColor(CDPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(GlassToggleStyle())
            }

            SettingsSection(title: "Shortcuts", symbol: "command") {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Drag files onto the CrossDrop icon in the menu bar to get them ready to send.")
                    bullet("In Finder, right-click files › Services › Send with CrossDrop. If it's missing, turn it on in System Settings › Keyboard › Keyboard Shortcuts › Services.")
                    bullet("⇧⌘V sends what you copied: a link opens on the phone, text lands on its clipboard.")
                }
            }

            SettingsSection(title: "Feedback", symbol: "speaker.wave.2") {
                Toggle(isOn: Binding(get: { model.soundOnDone }, set: { model.setSoundOnDone($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sound when done")
                            .font(CDFont.body)
                            .foregroundColor(CDPalette.textPrimary)
                        Text("A soft drop when files are verified. Follows your Mac's alert volume.")
                            .font(CDFont.caption)
                            .foregroundColor(CDPalette.textTertiary)
                    }
                }
                .toggleStyle(GlassToggleStyle())
            }

            SettingsSection(title: "Notifications", symbol: "bell") {
                Toggle(isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Requests and finished transfers")
                            .font(CDFont.body)
                            .foregroundColor(CDPalette.textPrimary)
                        Text("Notifications name the device, never the files.")
                            .font(CDFont.caption)
                            .foregroundColor(CDPalette.textTertiary)
                    }
                }
                .toggleStyle(GlassToggleStyle())
            }

            SettingsSection(title: "Privacy and security", symbol: "lock.shield") {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Files go straight from device to device on your local network. No cloud relay, account, analytics or telemetry.")
                    bullet("Connections are encrypted (AES-256-GCM) after both devices prove their identity keys. New devices confirm a matching six-digit code.")
                    bullet("Each received file is checked against its SHA-256 checksum before it appears in your folder.")
                    bullet("Your device key is stored in the macOS Keychain. Transfer history stays on this Mac.")
                    bullet("This is early software that hasn't been independently audited.")
                }
                Text("CrossDrop \(AppModel.appVersion)")
                    .font(CDFont.caption)
                    .foregroundColor(CDPalette.textTertiary)
                    .padding(.top, 4)
            }
        }
        .onAppear { nameDraft = model.deviceName }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(CDPalette.mint).frame(width: 5, height: 5).offset(y: -2)
            Text(text)
                .font(CDFont.callout)
                .foregroundColor(CDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.m) {
            Label(title, systemImage: symbol)
                .font(CDFont.headline)
                .foregroundColor(CDPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(CDSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

struct SegmentChoice: Identifiable {
    let id: Int
    let label: String
}

/// Glass segmented control for a handful of choices.
struct SegmentedGlass: View {
    let choices: [SegmentChoice]
    @Binding var selection: Int
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                let selected = selection == choice.id
                Button {
                    withAnimation(CDMotion.layout(reduceMotion)) { selection = choice.id }
                } label: {
                    Text(choice.label)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundColor(selected ? .white : CDPalette.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            if selected {
                                Capsule().fill(CDPalette.ink)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Color(hex: 0xD5E7DB), lineWidth: 1))
    }
}
