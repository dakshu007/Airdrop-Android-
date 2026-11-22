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
                    arrivals
                    sending
                    feedback
                } trailing: {
                    dripIsland
                    clipboard
                    notifications
                    shortcuts
                    privacy
                }
            } else {
                thisMac
                receiving
                arrivals
                sending
                dripIsland
                clipboard
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

    private var arrivals: some View {
        SettingsSection(title: "Arrivals", symbol: "tray.and.arrow.down") {
            SettingsRow {
                Toggle(isOn: Binding(get: { model.sortByType }, set: { model.setSortByType($0) })) {
                    labelStack("Smart arrival: sort by type",
                               detail: "After a file is verified, photos and screenshots move to Pictures › CrossDrop › From <device> – <date>, and documents to Documents › CrossDrop. Everything else, and files inside a sent folder, stay in \(model.destination.lastPathComponent). Nothing is overwritten.")
                }
                .toggleStyle(GlassToggleStyle())
            }
            GlassDivider()
            SettingsRow {
                Toggle(isOn: Binding(get: { model.heicToJpeg }, set: { model.setHeicToJpeg($0) })) {
                    labelStack("Also save HEIC photos as JPEG",
                               detail: "Phones send photos in original quality. This adds a JPEG copy for apps that can't open HEIC; the original is kept.")
                }
                .toggleStyle(GlassToggleStyle())
            }
        }
    }

    private var sending: some View {
        SettingsSection(title: "Sending", symbol: "paperplane") {
            SettingsRow {
                Toggle(isOn: Binding(get: { model.turboEnabled }, set: { model.setTurbo($0) })) {
                    VStack(alignment: .leading, spacing: ui(4)) {
                        HStack(spacing: ui.s) {
                            Text("Turbo for many files")
                                .font(ui.body)
                                .foregroundColor(CDPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Chip(text: "Experimental", symbol: "testtube.2", tint: CDPalette.amberText)
                        }
                        Text("When you send several files, asks the other device to take them over up to 4 connections at once, so one large file doesn't hold up the rest. Used only if the other device agrees. Speed gains haven't been measured yet and may be small on busy Wi-Fi.")
                            .font(ui.caption)
                            .foregroundColor(CDPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(GlassToggleStyle())
                .accessibilityLabel("Turbo for many files, experimental")
            }
            GlassDivider()
            SettingsRow {
                Text("When receiving, this Mac always lets a Turbo sender use extra connections, within its usual connection limit.")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dripIsland: some View {
        SettingsSection(title: "Drip Island", symbol: "drop") {
            SettingsRow {
                Toggle(isOn: Binding(get: { model.dripIslandEnabled }, set: { model.setDripIsland($0) })) {
                    labelStack("Show Drip Island while dragging files",
                               detail: "Drag files anywhere on your Mac and a glass island drops down from the top of the screen with nearby devices and your Shelf. Drop on a device to send, or on the Shelf to keep for later. It looks for devices only while it's showing.")
                }
                .toggleStyle(GlassToggleStyle())
            }
        }
    }

    private var clipboard: some View {
        SettingsSection(title: "Clipboard", symbol: "doc.on.clipboard") {
            SettingsRow {
                VStack(alignment: .leading, spacing: ui.s) {
                    Toggle(isOn: Binding(get: { model.offerClipboardToPhone }, set: { model.setOfferClipboardToPhone($0) })) {
                        labelStack("Send what I copy to my phone",
                                   detail: "Text you copy on this Mac lands on your phone's clipboard while it's nearby. Text only, up to 64 KB. Copies that password managers mark as concealed or temporary are skipped.")
                    }
                    .toggleStyle(GlassToggleStyle())
                    if model.offerClipboardToPhone {
                        clipboardStatus
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    /// Where the clipboard offer stands: no phone marked "mine", waiting, or the last result.
    @ViewBuilder
    private var clipboardStatus: some View {
        let hasMyPhone = model.trustedDevices.contains { $0.platform == "android" && $0.autoAccept && !$0.isTemporary }
        let text: String = {
            if !hasMyPhone {
                return "Needs a phone paired with \u{201C}This is my phone\u{201D} on. Pair one in Devices."
            }
            if let status = model.clipboardOfferStatus { return status }
            if model.clipboardWatching {
                return "Your phone is nearby. The next text you copy goes to it."
            }
            return "Waiting for your phone to be nearby. Nothing is checked until it is."
        }()
        HStack(alignment: .firstTextBaseline, spacing: ui(6)) {
            StatusDot(color: model.clipboardWatching ? CDPalette.mint : (hasMyPhone ? Color(hex: 0x9AA8A0) : CDPalette.amber))
            Text(text)
                .font(ui.caption)
                .foregroundColor(CDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ui(10))
        .padding(.vertical, ui(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.row, style: .inset)
        .accessibilityElement(children: .combine)
        Text("macOS may ask once whether CrossDrop can read the clipboard. CrossDrop reads it only after it changes, and the text goes straight to your phone over your Wi-Fi.")
            .font(ui.caption)
            .foregroundColor(CDPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var shortcuts: some View {
        SettingsSection(title: "Shortcuts", symbol: "command") {
            SettingsRow {
                VStack(alignment: .leading, spacing: ui.s) {
                    bullet("Drag files onto the CrossDrop icon in the menu bar to get them ready to send.")
                    bullet("In Finder, right-click files › Services › Send with CrossDrop. If it's missing, turn it on in System Settings › Keyboard › Keyboard Shortcuts › Services.")
                    bullet("⇧⌘V sends what you copied: a link opens on the phone, text lands on its clipboard.")
                    bullet("⇧⌘P asks your paired phone to take a photo; it arrives on this Mac's clipboard, ready to paste.")
                    bullet("Right-click the menu bar icon for quick actions: photos from your phone, the Shelf, waiting sends and Drip Rooms.")
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
