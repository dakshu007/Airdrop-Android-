import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

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
        PageScroll(allowsWide: true) {
            PageTitle(title: "Settings", subtitle: "Everything here stays on this Mac.")

            if ui.wide {
                TwoColumns {
                    thisMac
                    receiving
                    photos
                    feedback
                } trailing: {
                    notifications
                    shortcuts
                    privacy
                }
            } else {
                thisMac
                receiving
                photos
                shortcuts
                feedback
                notifications
                privacy
            }
        }
        .onAppear { nameDraft = model.deviceName }
    }

    // MARK: Sections

    private var thisMac: some View {
        SettingsSection(title: "This Mac", symbol: "laptopcomputer") {
            SettingsRow {
                VStack(alignment: .leading, spacing: ui.s) {
                    Text("Name shown to nearby devices")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                    HStack(spacing: ui.s) {
                        TextField("Device name", text: $nameDraft)
                            .textFieldStyle(.plain)
                            .font(ui.body)
                            .foregroundColor(CDPalette.textPrimary)
                            .focused($nameFocused)
                            .padding(.horizontal, ui(12))
                            .frame(height: ui(34))
                            .glassPanel(cornerRadius: CDRadius.field, style: .inset)
                            .modifier(FieldFocusBorder(focused: nameFocused, radius: CDRadius.field))
                            .onSubmit { model.rename(nameDraft) }
                            .accessibilityLabel("Device name")
                        Button("Save") { model.rename(nameDraft) }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || nameDraft == model.deviceName)
                    }
                }
            }
        }
    }

    private var receiving: some View {
        SettingsSection(title: "Receiving", symbol: "antenna.radiowaves.left.and.right") {
            SettingsRow {
                HStack(spacing: ui.l) {
                    labelStack("Who can send to this Mac",
                               detail: "My Devices: only devices you paired, and this Mac stays invisible to others.")
                    ReceiveModePicker()
                        .frame(width: ui(280))
                }
            }
            GlassDivider()
            SettingsRow {
                VStack(alignment: .leading, spacing: ui.s) {
                    HStack(spacing: ui.l) {
                        Text("Everyone: back to My Devices after")
                            .font(ui.body)
                            .foregroundColor(CDPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SegmentedGlass(choices: autoOffChoices.map { SegmentChoice(id: $0.minutes, label: $0.label) },
                                       selection: Binding(get: { model.autoOffMinutes },
                                                          set: { model.setAutoOff(minutes: $0) }),
                                       accessibilityName: "Everyone: back to My Devices after")
                    }
                    Text("With Everyone, this Mac announces its name and device ID on the local network; with My Devices, a random name instead. Every connection still proves its identity, and new devices must pair first.")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var photos: some View {
        SettingsSection(title: "Photos", symbol: "photo") {
            SettingsRow {
                Toggle(isOn: Binding(get: { model.heicToJpeg }, set: { model.setHeicToJpeg($0) })) {
                    labelStack("Also save HEIC photos as JPEG",
                               detail: "Phones send photos in original quality. This adds a JPEG copy for apps that can't open HEIC; the original is kept.")
                }
                .toggleStyle(GlassToggleStyle())
            }
        }
    }

    private var shortcuts: some View {
        SettingsSection(title: "Shortcuts", symbol: "command") {
            SettingsRow {
                VStack(alignment: .leading, spacing: ui.s) {
                    bullet("Drag files onto the CrossDrop icon in the menu bar to get them ready to send.")
                    bullet("In Finder, right-click files › Services › Send with CrossDrop. If it's missing, turn it on in System Settings › Keyboard › Keyboard Shortcuts › Services.")
                    bullet("⇧⌘V sends what you copied: a link opens on the phone, text lands on its clipboard.")
                    bullet("⌘+ and ⌘− make CrossDrop larger or smaller; ⌘0 returns to actual size. It also grows by itself in a large or full-screen window.")
                }
            }
        }
    }

    private var feedback: some View {
        SettingsSection(title: "Feedback", symbol: "speaker.wave.2") {
            SettingsRow {
                Toggle(isOn: Binding(get: { model.soundOnDone }, set: { model.setSoundOnDone($0) })) {
                    labelStack("Sound when done",
                               detail: "A soft drop when files are verified. Follows your Mac's alert volume.")
                }
                .toggleStyle(GlassToggleStyle())
            }
        }
    }

    private var notifications: some View {
        SettingsSection(title: "Notifications", symbol: "bell") {
            SettingsRow {
                Toggle(isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) })) {
                    labelStack("Requests and finished transfers",
                               detail: "Notifications name the device, never the files.")
                }
                .toggleStyle(GlassToggleStyle())
            }
        }
    }

    private var privacy: some View {
        SettingsSection(title: "Privacy and security", symbol: "lock.shield") {
            SettingsRow {
                VStack(alignment: .leading, spacing: ui.s) {
                    bullet("Files go straight from device to device on your local network. No cloud relay, account, analytics or telemetry.")
                    bullet("Connections are encrypted (AES-256-GCM) after both devices prove their identity keys. New devices confirm a matching six-digit code.")
                    bullet("Each received file is checked against its SHA-256 checksum before it appears in your folder.")
                    bullet("Your device key is stored in the macOS Keychain. Transfer history stays on this Mac.")
                    bullet("This is early software that hasn't been independently audited.")
                }
            }
            GlassDivider()
            SettingsRow {
                Text("CrossDrop \(AppModel.appVersion)")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textTertiary)
            }
        }
    }

    // MARK: Pieces

    /// Setting name with a one-line explanation under it.
    private func labelStack(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: ui(2)) {
            Text(title)
                .font(ui.body)
                .foregroundColor(CDPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(ui.caption)
                .foregroundColor(CDPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ui.s) {
            Circle()
                .fill(CDPalette.mint)
                .frame(width: ui(5), height: ui(5))
                .offset(y: -ui(2))
            Text(text)
                .font(ui.callout)
                .foregroundColor(CDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A settings card: a header, then rows separated by full-width hairlines. The card's
/// padding is set so the header-to-row and row-to-edge gaps match the row rhythm.
struct SettingsSection<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content
    @Environment(\.cdScale) private var ui

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: symbol)
                .font(ui.headline)
                .foregroundColor(CDPalette.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, ui(6))
            content
        }
        .padding(.horizontal, ui(CDLayout.cardPadding))
        .padding(.top, ui(CDLayout.cardPadding - 2))
        .padding(.bottom, ui(CDLayout.cardPadding - CDLayout.rowPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

/// One row inside a `SettingsSection` (or any card list): the same vertical padding
/// everywhere, full width so hairlines between rows line up.
struct SettingsRow<Content: View>: View {
    let content: Content
    @Environment(\.cdScale) private var ui

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, ui(CDLayout.rowPadding))
    }
}
