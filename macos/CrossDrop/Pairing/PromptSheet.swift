import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Pairing confirmation or incoming-offer approval, shown as a glass card over the window.
struct PromptCard: View {
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
        .padding(.horizontal, 28)
        .padding(.vertical, 30)
        .glassPanel(cornerRadius: CDRadius.panel)
        .onAppear { model.presentedPromptId = prompt.id }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct PairingContent: View {
    let prompt: PairingPrompt
    let waiting: Bool
    let respond: (Bool) -> Void

    var body: some View {
        VStack(spacing: CDSpacing.l) {
            DeviceAvatar(platform: prompt.peer.platform, size: 56)
            VStack(spacing: 6) {
                Text("Pair with \(prompt.peer.name)?")
                    .font(CDFont.title)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Text("Make sure \(prompt.peer.name) shows the same code.")
                    .font(CDFont.body)
                    .foregroundColor(CDPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .legibleText()

            Text(Format.code(prompt.code))
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(4)
                .foregroundColor(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .glassPanel(cornerRadius: CDRadius.card, style: .inset)
                .shadow(color: Color.white.opacity(0.15), radius: 18)
                .accessibilityLabel("Pairing code \(prompt.code.map { String($0) }.joined(separator: " "))")

            Group {
                if waiting {
                    HStack(spacing: CDSpacing.s) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for \(prompt.peer.name) to confirm…")
                    }
                } else {
                    Text("Only continue if both codes match exactly. Paired devices can be forgotten any time in Devices.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(CDFont.caption)
            .foregroundColor(CDPalette.textSecondary)

            HStack(spacing: CDSpacing.m) {
                Button("Cancel") { respond(false) }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Codes Match") { respond(true) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(waiting)
            }
            .padding(.top, 4)
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
            DeviceAvatar(platform: offer.peer.platform, size: 56)
            VStack(spacing: 8) {
                Text("\(offer.peer.name) wants to send you \(Format.files(offer.files.count))")
                    .font(CDFont.title)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .legibleText()
                HStack(spacing: 6) {
                    Chip(text: trusted ? "Paired" : "Not paired", symbol: trusted ? "checkmark.seal.fill" : "seal",
                         tint: trusted ? CDPalette.mint : .white)
                    Chip(text: Format.bytes(offer.totalBytes))
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(offer.files.enumerated()), id: \.offset) { index, file in
                        HStack(spacing: CDSpacing.m) {
                            FileIcon(url: nil, name: file.name, size: 26)
                            Text(FileNaming.sanitize(file.name))
                                .font(CDFont.callout)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: CDSpacing.s)
                            Text(Format.bytes(file.size))
                                .font(CDFont.caption.monospacedDigit())
                                .foregroundColor(CDPalette.textSecondary)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, CDSpacing.m)
                        if index < offer.files.count - 1 {
                            GlassDivider().padding(.leading, 50)
                        }
                    }
                }
            }
            .frame(height: min(190, CGFloat(offer.files.count) * 41))
            .glassPanel(cornerRadius: 16, style: .inset)

            Text("Saved to \(destination.lastPathComponent) after each file's checksum is verified. Nothing is overwritten.")
                .font(CDFont.caption)
                .foregroundColor(CDPalette.textSecondary)
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
            .padding(.top, 4)
        }
    }
}
