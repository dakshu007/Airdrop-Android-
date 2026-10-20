import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Pairing confirmation or incoming-offer approval.
struct PromptSheet: View {
    @EnvironmentObject private var model: AppModel
    let prompt: PromptItem

    var body: some View {
        Group {
            switch prompt {
            case .pairing(let pairing, _):
                PairingContent(prompt: pairing, waiting: model.waitingPairingIds.contains(pairing.id),
                               respond: { model.respond(to: prompt, accept: $0) })
            case .offer(let offer, _):
                OfferContent(offer: offer, trusted: model.isTrusted(offer.peer.deviceId),
                             destination: model.destination,
                             respond: { model.respond(to: prompt, accept: $0) })
            }
        }
        .padding(CDSpacing.xxl)
        .frame(width: 460)
        .onAppear { model.presentedPromptId = prompt.id }
    }
}

private struct PairingContent: View {
    let prompt: PairingPrompt
    let waiting: Bool
    let respond: (Bool) -> Void

    var body: some View {
        VStack(spacing: CDSpacing.l) {
            DeviceAvatar(platform: prompt.peer.platform, size: 60)
            Text("Pair with \(prompt.peer.name)?")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Check that \(prompt.peer.name) shows the same code. Only continue if both codes match exactly.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(Format.code(prompt.code))
                .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(3)
                .padding(.horizontal, CDSpacing.xl)
                .padding(.vertical, CDSpacing.m)
                .cdGlass(radius: CDRadius.large)
                .textSelection(.disabled)
                .accessibilityLabel("Pairing code \(prompt.code.map { String($0) }.joined(separator: " "))")

            if waiting {
                HStack(spacing: CDSpacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for \(prompt.peer.name) to confirm…")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Pairing lets these devices recognise each other next time. You can forget a device at any time in Devices.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: CDSpacing.m) {
                Button("Cancel") { respond(false) }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Codes Match") { respond(true) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(waiting)
            }
        }
    }
}

private struct OfferContent: View {
    let offer: OfferPrompt
    let trusted: Bool
    let destination: URL
    let respond: (Bool) -> Void

    var body: some View {
        VStack(spacing: CDSpacing.l) {
            DeviceAvatar(platform: offer.peer.platform, size: 60)
            VStack(spacing: 6) {
                Text("\(offer.peer.name) wants to send you \(Format.files(offer.files.count))")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                HStack(spacing: 4) {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "seal")
                    Text(trusted ? "Paired device" : "Not paired")
                    Text("· \(Format.bytes(offer.totalBytes))")
                }
                .font(.system(size: 12))
                .foregroundColor(trusted ? CDPalette.mint : .secondary)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(offer.files.enumerated()), id: \.offset) { _, file in
                        HStack(spacing: CDSpacing.m) {
                            FileIcon(url: nil, name: file.name, size: 26)
                            Text(FileNaming.sanitize(file.name))
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(file.size))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, CDSpacing.m)
                    }
                }
            }
            .frame(maxHeight: 200)
            .cdGlass(radius: CDRadius.small)

            Text("Files are checked against their checksums and saved to \(destination.lastPathComponent). Nothing is overwritten.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: CDSpacing.m) {
                Button("Decline") { respond(false) }
                    .buttonStyle(GlassButtonStyle(destructive: true))
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { respond(true) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
