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

    private var snapshot: TransferSnapshot { item.snapshot }
    private var outgoing: Bool { snapshot.direction == .outgoing }

    var body: some View {
        HStack(alignment: .top, spacing: CDSpacing.m) {
            leadingIcon

            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                HStack(alignment: .firstTextBaseline, spacing: CDSpacing.s) {
                    Text(title)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: CDSpacing.s)
                    statusLabel
                }
                Text(subtitle)
                    .font(compact ? CDFont.caption : CDFont.callout)
                    .foregroundColor(CDPalette.textSecondary)
                    .lineLimit(1)

                if showsProgress {
                    CapsuleProgress(value: item.fraction, tint: outgoing ? .white : CDPalette.mint)
                        .padding(.top, 2)
                    TimelineView(.periodic(from: Date(), by: 1)) { _ in
                        Text(progressText)
                            .font(CDFont.caption.monospacedDigit())
                            .foregroundColor(CDPalette.textTertiary)
                    }
                }

                if hasProblem {
                    Text(TransferText.errorMessage(snapshot))
                        .font(CDFont.caption)
                        .foregroundColor(snapshot.phase == .failed ? CDPalette.coral : CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !compact {
                    actions
                }
            }
        }
        .padding(compact ? CDSpacing.m : CDSpacing.l)
        .glassPanel(cornerRadius: compact ? 16 : CDRadius.card, style: compact ? .inset : .regular)
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
                .font(.system(size: compact ? 7 : 9, weight: .heavy))
                .foregroundColor(.black.opacity(0.8))
                .frame(width: compact ? 13 : 17, height: compact ? 13 : 17)
                .background(Circle().fill(outgoing ? Color.white : CDPalette.mint))
                .offset(x: 3, y: 3)
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
        HStack(spacing: 5) {
            if snapshot.phase == .completed {
                Image(systemName: "checkmark.circle.fill").foregroundColor(CDPalette.mint)
            } else if snapshot.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(CDPalette.coral)
            } else if !snapshot.phase.isFinished && snapshot.phase != .transferring {
                ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 14, height: 14)
            }
            Text(TransferText.status(snapshot))
        }
        .font(.system(size: 11, weight: .medium))
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

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: CDSpacing.s) {
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
            if snapshot.phase.isFinished {
                Button("Dismiss") { model.dismiss(item) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.top, 4)
    }
}
