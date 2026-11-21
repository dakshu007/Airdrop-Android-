import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct ReceiveView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    var body: some View {
        PageScroll(allowsWide: true) {
            PageTitle(title: "Receive", subtitle: "Let nearby devices find this Mac and send you files.",
                      trailing: AnyView(StatusPill(text: model.receivingEnabled ? "Visible nearby" : "Not visible",
                                                   dot: ReceiverText.color(model.receiverStatus))))
            ReceiveToggleCard()
            HStack(alignment: .top, spacing: ui(CDLayout.cardGap)) {
                DestinationCard()
                PrivacyCard()
            }
            .fixedSize(horizontal: false, vertical: true)
            let incoming = model.incomingTransfers
            if !incoming.isEmpty {
                SectionHeader(title: "Incoming", detail: "This session")
                    .padding(.top, ui.s)
                if ui.wide {
                    PairedRows(incoming) { item in
                        TransferCard(item: item)
                    }
                } else {
                    ForEach(incoming) { item in
                        TransferCard(item: item)
                    }
                }
            }
        }
    }
}

struct ReceiveToggleCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    private var headline: String {
        switch model.receiveMode {
        case .off: return "Drip is napping"
        case .mine: return "Ready for your devices"
        case .everyone: return "Visible to everyone nearby"
        }
    }

    private var explanation: String {
        switch model.receiveMode {
        case .off: return "Nobody can send to this Mac. You can still send."
        case .mine: return "Devices you paired can send any time. Everyone else can't see this Mac."
        case .everyone: return "Anyone nearby can ask to send. New devices confirm a code first, and you approve each transfer."
        }
    }

    var body: some View {
        HStack(spacing: ui.xl) {
            // Drip naps while this Mac is hidden and waves while it's visible.
            DripView(pose: model.receivingEnabled ? .welcome : .sleepy, size: 104, motion: .bob)
                .id(model.receivingEnabled)
                .frame(width: ui(104), height: ui(96))

            VStack(alignment: .leading, spacing: ui(10)) {
                HStack(spacing: ui(8)) {
                    Text(headline)
                        .font(ui.title)
                        .foregroundColor(CDPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusDot(color: ReceiverText.color(model.receiverStatus))
                }
                Text(explanation)
                    .font(ui.body)
                    .foregroundColor(CDPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ReceiveModePicker()
                    .frame(maxWidth: ui(360))
                if let date = model.autoOffDate {
                    Text("Back to My Devices at \(date.formatted(date: .omitted, time: .shortened))")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                }
                if model.receiverStatus == .localNetworkDenied {
                    Label("Allow CrossDrop in System Settings › Privacy & Security › Local Network.",
                          systemImage: "exclamationmark.triangle")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .legibleText()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

struct DestinationCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: ui.m) {
            Label("Saved to", systemImage: "folder")
                .font(ui.headline)
                .foregroundColor(CDPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: ui.m) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.destination.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: ui(34), height: ui(34))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ui(2)) {
                    Text(model.destination.lastPathComponent)
                        .font(ui.font(13, .medium))
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.destination.deletingLastPathComponent().path)
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: ui.s) {
                Button("Change…") { model.chooseDestination() }
                    .buttonStyle(GlassButtonStyle())
                Button("Open") { NSWorkspace.shared.open(model.destination) }
                    .buttonStyle(GlassButtonStyle())
            }
            Text("Nothing is overwritten. A second copy becomes “photo (1).jpg”.")
                .font(ui.caption)
                .foregroundColor(CDPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

struct PrivacyCard: View {
    @Environment(\.cdScale) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: ui.m) {
            Label("Private by design", systemImage: "lock.shield")
                .font(ui.headline)
                .foregroundColor(CDPalette.textPrimary)
            point("wifi", "Files travel directly over your local network. No cloud, no account.")
            point("number", "New devices confirm a matching 6-digit code on both screens.")
            point("checkmark.seal", "Every file is checked (SHA-256) before it appears.")
        }
        .padding(ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: CDRadius.card)
        .accessibilityElement(children: .combine)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ui(10)) {
            Image(systemName: symbol)
                .font(ui.system(11, .semibold))
                .foregroundColor(CDPalette.textPrimary)
                .frame(width: ui(14))
            Text(text)
                .font(ui.callout)
                .foregroundColor(CDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
