import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// One transfer: who, what, live progress, and the actions that make sense right now.
struct TransferCard: View {
    @EnvironmentObject private var model: AppModel
    let item: TransferItem
    var compact = false
    @Environment(\.cdScale) private var ui

    private var snapshot: TransferSnapshot { item.snapshot }
    private var outgoing: Bool { snapshot.direction == .outgoing }

    var body: some View {
        HStack(alignment: .top, spacing: ui.m) {
            leadingIcon

            VStack(alignment: .leading, spacing: ui(compact ? 5 : 7)) {
                HStack(alignment: .firstTextBaseline, spacing: ui.s) {
                    Text(title)
                        .font(ui.font(compact ? 12 : 13.5, .semibold))
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: ui.s)
                    statusLabel
                }
                Text(subtitle)
                    .font(compact ? ui.caption : ui.callout)
                    .foregroundColor(CDPalette.textSecondary)
                    .lineLimit(1)

                if showsProgress {
                    CapsuleProgress(value: item.fraction)
                        .padding(.top, ui(2))
                    TimelineView(.periodic(from: Date(), by: 1)) { _ in
                        Text(progressText)
                            .font(ui.caption.monospacedDigit())
                            .lineLimit(1)
                            .foregroundColor(CDPalette.textTertiary)
                    }
                }

                if let expiry = expiryText {
                    ExpiryLabel(text: expiry, done: false)
                        .accessibilityLabel(expiry)
                }

                if hasProblem {
                    Text(TransferText.errorMessage(snapshot))
                        .font(ui.caption)
                        .foregroundColor(snapshot.phase == .failed ? CDPalette.coral : CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !compact && hasActions {
                    actions
                }
            }
        }
        .padding(compact ? ui.m : ui(CDLayout.cardPadding))
        // Full cards fill the height offered, so cards side by side end level.
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : CGFloat.infinity, alignment: .topLeading)
        .glassPanel(cornerRadius: compact ? CDRadius.tile : CDRadius.card, style: compact ? .inset : .regular)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        let size: CGFloat = compact ? 30 : 40
        ZStack(alignment: .bottomTrailing) {
            if let file = singleFile {
                FileIcon(url: file.savedURL ?? file.sourceURL, name: file.name, size: size)
            } else {
                DeviceAvatar(platform: snapshot.peerPlatform, size: size)
            }
            Image(systemName: outgoing ? "arrow.up" : "arrow.down")
                .font(ui.system(compact ? 7 : 9, .heavy))
                .foregroundColor(.white)
                .frame(width: ui(compact ? 13 : 17), height: ui(compact ? 13 : 17))
                .background(Circle().fill(outgoing ? CDPalette.ink : CDPalette.mint))
                .offset(x: ui(3), y: ui(3))
                .accessibilityHidden(true)
        }
    }

    private var singleFile: TransferFileState? {
        snapshot.files.count == 1 ? snapshot.files.first : nil
    }

    private var title: String {
        let names = snapshot.files.map { $0.name }
        guard let first = names.first else { return outgoing ? "To \(snapshot.peerName)" : "From \(snapshot.peerName)" }
        return names.count > 1 ? "\(first) + \(names.count - 1) more" : first
    }

    private var subtitle: String {
        let who = outgoing ? "To \(snapshot.peerName)" : "From \(snapshot.peerName)"
        return "\(who) · \(Format.bytes(snapshot.totalBytes))"
    }

    private var statusLabel: some View {
        HStack(spacing: ui(5)) {
            if snapshot.phase == .completed {
                Image(systemName: "checkmark.circle.fill").foregroundColor(CDPalette.mint)
            } else if snapshot.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(CDPalette.coral)
            } else if !snapshot.phase.isFinished && snapshot.phase != .transferring {
                ProgressView().controlSize(.small).scaleEffect(0.65 * ui.factor).frame(width: ui(14), height: ui(14))
            }
            Text(TransferText.status(snapshot))
        }
        .font(ui.font(11, .medium))
        .foregroundColor(CDPalette.textSecondary)
        .lineLimit(1)
    }

    private var showsProgress: Bool {
        snapshot.phase == .transferring
    }

    private var hasProblem: Bool {
        snapshot.phase == .failed || snapshot.phase == .rejected
            || (snapshot.phase == .cancelled && snapshot.error?.fromPeer == true)
    }

    private var progressText: String {
        var parts = ["\(Format.bytes(snapshot.bytesTransferred)) of \(Format.bytes(snapshot.totalBytes))"]
        if let rate = item.bytesPerSecond, rate > 0 { parts.append(Format.rate(rate)) }
        if let remaining = item.remainingSeconds(now: ProcessInfo.processInfo.systemUptime) {
            parts.append("about \(Format.duration(remaining)) left")
        }
        return parts.joined(separator: " · ")
    }

    /// Whether `actions` has any button to show (none while awaiting approval).
    private var hasActions: Bool {
        (!snapshot.phase.isFinished && snapshot.phase != .awaitingApproval)
            || (!outgoing && snapshot.phase == .completed)
            || model.canRetry(item)
            || snapshot.phase.isFinished
    }

    /// Expiring drops (§9.8). Outgoing: what was asked of the receiver. Incoming: when this
    /// Mac moves the saved files to the Trash (until the user keeps them in History).
    private var expiryText: String? {
        guard snapshot.kind == .files, let seconds = snapshot.expiresAfter else { return nil }
        if outgoing { return ExpiryText.request(seconds) }
        if snapshot.phase == .completed,
           let date = model.expiringFiles.first(where: { $0.transferId == snapshot.id })?.deleteAt {
            return "Deletes " + date.formatted(date: .abbreviated, time: .shortened)
        }
        guard !snapshot.phase.isFinished else { return nil }
        return "Deletes \(ExpiryText.duration(seconds)) after arrival"
    }

    @ViewBuilder
    private var actions: some View {
        // Wraps onto a second line in a narrow column instead of clipping a button.
        FlowRow(spacing: ui.s) {
            if !snapshot.phase.isFinished && snapshot.phase != .awaitingApproval {
                Button("Cancel") { model.cancel(item) }
                    .buttonStyle(GlassButtonStyle(destructive: true))
                    .accessibilityLabel("Cancel transfer \(outgoing ? "to" : "from") \(snapshot.peerName)")
            }
            if !outgoing && snapshot.phase == .completed {
                Button {
                    model.reveal(snapshot.files.compactMap { $0.savedURL })
                } label: {
                    Label("Show in Finder", systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            if model.canRetry(item) {
                Button {
                    model.retry(item)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            if model.canSendWhenNearby(item) {
                Button {
                    model.sendWhenNearby(item)
                } label: {
                    Label("Send When Nearby", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(GlassButtonStyle())
                .help("Keep this send and deliver it automatically when \(snapshot.peerName) is back on the same network")
                .accessibilityLabel("Send to \(snapshot.peerName) when it's nearby")
            }
            if snapshot.phase.isFinished {
                Button("Dismiss") { model.dismiss(item) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.top, ui(4))
    }
}
