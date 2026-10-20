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
        AutoOffChoice(minutes: 10, label: "After 10 minutes"),
        AutoOffChoice(minutes: 30, label: "After 30 minutes"),
        AutoOffChoice(minutes: 60, label: "After 1 hour"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.l) {
            SettingsSection(title: "This Mac", symbol: "laptopcomputer") {
                Text("Name shown to nearby devices").font(.system(size: 12)).foregroundColor(.secondary)
                HStack {
                    TextField("Device name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.rename(nameDraft) }
                        .accessibilityLabel("Device name")
                    Button("Save") { model.rename(nameDraft) }
                        .buttonStyle(GlassButtonStyle())
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || nameDraft == model.deviceName)
                }
            }

            SettingsSection(title: "Receiving", symbol: "antenna.radiowaves.left.and.right") {
                Toggle("Let nearby devices send files to this Mac",
                       isOn: Binding(get: { model.receivingEnabled }, set: { model.setReceiving($0) }))
                    .toggleStyle(.switch)
                Picker("Turn off automatically", selection: Binding(get: { model.autoOffMinutes },
                                                                     set: { model.setAutoOff(minutes: $0) })) {
                    ForEach(autoOffChoices) { choice in
                        Text(choice.label).tag(choice.minutes)
                    }
                }
                .frame(maxWidth: 360)
                if let date = model.autoOffDate {
                    Text("Receiving turns off at \(date.formatted(date: .omitted, time: .shortened)).")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text("While receiving is on, this Mac announces itself on the local network with its name and a random device ID. Every connection still has to prove its identity, and unknown devices must pair first.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection(title: "Saving", symbol: "folder") {
                Text("Received files are saved to").font(.system(size: 12)).foregroundColor(.secondary)
                HStack {
                    Image(systemName: "folder.fill").foregroundColor(CDPalette.sky)
                    Text(model.destination.path)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Change…") { model.chooseDestination() }
                        .buttonStyle(GlassButtonStyle())
                    Button("Show") { NSWorkspace.shared.open(model.destination) }
                        .buttonStyle(GlassButtonStyle())
                }
                Text("Existing files are never overwritten: a new copy gets a number, like “photo (1).jpg”.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            SettingsSection(title: "Notifications", symbol: "bell") {
                Toggle("Show notifications for requests and finished transfers",
                       isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) }))
                    .toggleStyle(.switch)
                Text("Notifications name the device but never the files.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            SettingsSection(title: "Privacy and security", symbol: "lock.shield") {
                VStack(alignment: .leading, spacing: 6) {
                    bullet("Files go straight from device to device on your local network. There is no cloud relay, account, analytics or telemetry.")
                    bullet("Connections are encrypted (AES-256-GCM) after both devices prove their identity keys. New devices must confirm a matching six-digit code.")
                    bullet("Each received file is checked against its SHA-256 checksum before it appears in your folder.")
                    bullet("Your device key is stored in the macOS Keychain. Transfer history stays on this Mac.")
                    bullet("This is early software that hasn't been independently audited.")
                }
                Text("CrossDrop \(AppModel.appVersion)")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
        .onAppear { nameDraft = model.deviceName }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundColor(.secondary)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
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
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(CDSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cdGlass(radius: CDRadius.medium)
    }
}
