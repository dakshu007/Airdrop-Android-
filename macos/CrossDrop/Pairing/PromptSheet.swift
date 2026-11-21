import SwiftUI
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Pairing confirmation or incoming-offer approval, shown as a glass card over the window.
struct PromptCard: View {
    @EnvironmentObject private var model: AppModel
    let prompt: PromptItem
    @Environment(\.cdScale) private var ui

    var body: some View {
        Group {
            switch prompt {
            case .pairing(let pairing, _):
                PairingContent(prompt: pairing, waiting: model.waitingPairingIds.contains(pairing.id),
                               respond: { accept, mine in model.respond(to: prompt, accept: accept, mine: mine) })
            case .offer(let offer, _):
                OfferContent(offer: offer, trusted: model.isTrusted(offer.peer.deviceId),
                             destination: model.destination,
                             respond: { model.respond(to: prompt, accept: $0) })
            }
        }
        .padding(.horizontal, ui(28))
        .padding(.vertical, ui(28))
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: CDRadius.panel, style: .floating)
        .onAppear { model.presentedPromptId = prompt.id }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct PairingContent: View {
    let prompt: PairingPrompt
    let waiting: Bool
    let respond: (_ accept: Bool, _ mine: Bool) -> Void
    /// "This is my device": its files then arrive without asking.
    @State private var mine = false
    @Environment(\.cdScale) private var ui

    var body: some View {
        VStack(spacing: ui.l) {
            StatusPill(text: "New device · \(prompt.peer.name)", dot: Color(hex: 0xE0A100))
            DripView(pose: .pairing, size: 140, motion: .bob)
                .padding(.vertical, -ui(10))
            VStack(spacing: ui(6)) {
                Text("Do these match?")
                    .font(ui.font(26, .bold))
                    .foregroundColor(CDPalette.textPrimary)
                    .multilineTextAlignment(.center)
                Text("\(prompt.peer.name) is showing a code too. Pair only if both are the same.")
                    .font(ui.body)
                    .foregroundColor(CDPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .legibleText()

            CodeTiles(code: prompt.code)
                .padding(.vertical, ui(18))
                .padding(.horizontal, ui(22))
                .background(RoundedRectangle(cornerRadius: ui(24), style: .continuous).fill(CDPalette.mintSoft.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: ui(24), style: .continuous).strokeBorder(Color.white.opacity(0.95), lineWidth: 1))

            Group {
                if waiting {
                    HStack(spacing: ui.s) {
                        ProgressView().controlSize(.small).scaleEffect(ui.factor)
                            .frame(width: ui(16), height: ui(16))
                        Text("Waiting for \(prompt.peer.name) to confirm…")
                    }
                } else {
                    Text("You only do this once per device. Paired devices can be forgotten any time in Devices.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(ui.caption)
            .foregroundColor(CDPalette.textSecondary)

            if !waiting {
                Toggle(isOn: $mine) {
                    VStack(alignment: .leading, spacing: ui(2)) {
                        Text("This is my device")
                            .font(ui.headline)
                            .foregroundColor(CDPalette.textPrimary)
                        Text("Files from it arrive without asking.")
                            .font(ui.caption)
                            .foregroundColor(CDPalette.textSecondary)
                    }
                }
                .toggleStyle(GlassToggleStyle())
                .frame(maxWidth: ui(340))
            }

            HStack(spacing: ui.m) {
                Button(waiting ? "Cancel" : "They Don't Match") { respond(false, false) }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Codes Match") { respond(true, mine) }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(waiting)
            }
            .padding(.top, ui(4))
        }
    }
}

private struct OfferContent: View {
    let offer: OfferPrompt
    let trusted: Bool
    let destination: URL
    let respond: (Bool) -> Void
    @Environment(\.cdScale) private var ui

    private var offerLine: String {
        switch offer.kind {
        case .link: return "\(offer.peer.name) wants to send you a link"
        case .text: return "\(offer.peer.name) wants to send you some text"
        case .files: return "\(offer.peer.name) wants to send you \(Format.files(offer.files.count))"
        }
    }

    var body: some View {
        VStack(spacing: ui.l) {
            DripView(pose: .incoming, size: 150, motion: .pop)
                .padding(.vertical, -ui(12))
            VStack(spacing: ui(8)) {
                Text(offer.kind == .files ? "Files are on their way" : (offer.kind == .link ? "A link is on its way" : "Some text is on its way"))
                    .font(ui.font(24, .bold))
                    .foregroundColor(CDPalette.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(offerLine)
                    .font(ui.body)
                    .foregroundColor(CDPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: ui(6)) {
                    Chip(text: trusted ? "Paired" : "Not paired", symbol: trusted ? "checkmark.seal.fill" : "seal",
                         tint: trusted ? CDPalette.mint : CDPalette.amber)
                    Chip(text: Format.bytes(offer.totalBytes))
                }
            }

            if offer.kind == .files {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(offer.files.enumerated()), id: \.offset) { index, file in
                        HStack(spacing: ui.m) {
                            FileIcon(url: nil, name: file.name, size: 26)
                            Text(file.displayPath)
                                .font(ui.callout)
                                .foregroundColor(CDPalette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: ui.s)
                            Text(Format.bytes(file.size))
                                .font(ui.caption.monospacedDigit())
                                .foregroundColor(CDPalette.textSecondary)
                        }
                        .padding(.vertical, ui(7))
                        .padding(.horizontal, ui.m)
                        if index < offer.files.count - 1 {
                            GlassDivider()
                                .padding(.leading, ui.m + ui(26) + ui.m)
                                .padding(.trailing, ui.m)
                        }
                    }
                }
            }
            .frame(height: ui(min(190, CGFloat(offer.files.count) * 41)))
            .glassPanel(cornerRadius: CDRadius.tile, style: .inset)
            .clipShape(RoundedRectangle(cornerRadius: ui(CDRadius.tile), style: .continuous))
            }

            Text(offer.kind == .link
                 ? "If you accept, it opens in your browser (web links only)."
                 : offer.kind == .text
                 ? "If you accept, it's copied to your clipboard. It isn't saved as a file."
                 : "Saved to \(destination.lastPathComponent) after each file's checksum is verified. Nothing is overwritten.")
                .font(ui.caption)
                .foregroundColor(CDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: ui.m) {
                Button("Decline") { respond(false) }
                    .buttonStyle(GlassButtonStyle(destructive: true))
                    .keyboardShortcut(.cancelAction)
                Button("Accept") { respond(true) }
                    .buttonStyle(PrimaryButtonStyle(large: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, ui(4))
        }
    }
}
