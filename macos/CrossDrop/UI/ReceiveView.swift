import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct ReceiveView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        PageScroll {
            PageTitle(title: "Receive", subtitle: "Let nearby devices find this Mac and send you files.",
                      trailing: AnyView(StatusPill(text: model.receivingEnabled ? "Visible nearby" : "Not visible",
                                                   dot: ReceiverText.color(model.receiverStatus))))
            ReceiveToggleCard()
            HStack(alignment: .top, spacing: CDSpacing.l) {
                DestinationCard()
                PrivacyCard()
            }
            .fixedSize(horizontal: false, vertical: true)
            let incoming = model.incomingTransfers
            if !incoming.isEmpty {
                SectionHeader(title: "Incoming", detail: "This session")
                    .padding(.top, CDSpacing.s)
                ForEach(incoming) { item in
                    TransferCard(item: item)
                }
            }
        }
    }
}

struct ReceiveToggleCard: View {
    @EnvironmentObject private var model: AppModel

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
        HStack(spacing: CDSpacing.l) {
            // Drip naps while this Mac is hidden and waves while it's visible.
            DripView(pose: model.receivingEnabled ? .welcome : .sleepy, size: 104, motion: .bob)
                .id(model.receivingEnabled)
                .frame(width: 104, height: 90)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(headline)
                        .font(CDFont.title)
                        .foregroundColor(CDPalette.textPrimary)
                    StatusDot(color: ReceiverText.color(model.receiverStatus))
                }
                Text(explanation)
                    .font(CDFont.body)
                    .foregroundColor(CDPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ReceiveModePicker()
                    .frame(maxWidth: 360)
                if let date = model.autoOffDate {
                    Text("Back to My Devices at \(date.formatted(date: .omitted, time: .shortened))")
                        .font(CDFont.caption)
                        .foregroundColor(CDPalette.textTertiary)
                }
            }
            .legibleText()
            Spacer(minLength: 0)
        .padding(CDSpacing.xl)
        .glassPanel(cornerRadius: CDRadius.panel)
        .overlay(alignment: .bottomLeading) {
            if model.receiverStatus == .localNetworkDenied {
                Text("Allow CrossDrop in System Settings › Privacy & Security › Local Network.")
                    .font(CDFont.caption)
                    .foregroundColor(CDPalette.amber)
                    .padding(.leading, 96)
                    .padding(.bottom, 10)
            }
        }
    }
}

struct DestinationCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.m) {
            Label("Saved to", systemImage: "folder")
                .font(CDFont.headline)
                .foregroundColor(CDPalette.textPrimary)
            HStack(spacing: CDSpacing.m) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.destination.path))
                    .resizable()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.destination.lastPathComponent)
                        .font(CDFont.body.weight(.medium))
                        .foregroundColor(CDPalette.textPrimary)
                    Text(model.destination.deletingLastPathComponent().path)
                        .font(CDFont.caption)
                        .foregroundColor(CDPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: CDSpacing.s) {
                Button("Change…") { model.chooseDestination() }
                    .buttonStyle(GlassButtonStyle())
                Button("Open") { NSWorkspace.shared.open(model.destination) }
                    .buttonStyle(GlassButtonStyle())
            }
            Text("Nothing is overwritten. A second copy becomes “photo (1).jpg”.")
                .font(CDFont.caption)
                .foregroundColor(CDPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CDSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: CDRadius.card)
    }
}

struct PrivacyCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: CDSpacing.m) {
            Label("Private by design", systemImage: "lock.shield")
                .font(CDFont.headline)
                .foregroundColor(CDPalette.textPrimary)
            point("wifi", "Files travel directly over your local network. No cloud, no account.")
            point("number", "New devices confirm a matching 6-digit code on both screens.")
            point("checkmark.seal", "Every file is checked (SHA-256) before it appears.")
        }
        .padding(CDSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: CDRadius.card)
        .accessibilityElement(children: .combine)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(CDPalette.textPrimary)
                .frame(width: 14)
            Text(text)
                .font(CDFont.callout)
                .foregroundColor(CDPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
