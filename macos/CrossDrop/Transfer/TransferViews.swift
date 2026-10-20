import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct TransferCard: View {
    @EnvironmentObject private var model: AppModel
    let item: TransferItem
    var compact = false

    private var snapshot: TransferSnapshot { item.snapshot }
    private var outgoing: Bool { snapshot.direction == .outgoing }

    var body: some View {
        HStack(alignment: .top, spacing: CDSpacing.m) {
            ZStack(alignment: .bottomTrailing) {
                DeviceAvatar(platform: snapshot.peerPlatform, size: compact ? 32 : 42)
                Image(systemName: outgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: compact ? 12 : 15))
                    .foregroundColor(outgoing ? CDPalette.sky : CDPalette.mint)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    .offset(x: 3, y: 3)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(outgoing ? "To \(snapshot.peerName)" : "From \(snapshot.peerName)")
                        .font(.system(size: compact ? 12 : 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: CDSpacing.s)
                    statusLabel
                }
                Text(fileSummary)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if showsProgress {
                    CapsuleProgress(value: item.fraction)
                    TimelineView(.periodic(from: Date(), by: 1)) { _ in
                        Text(progressText)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }

                if hasProblem {
                    Text(TransferText.errorMessage(snapshot))
                        .font(.system(size: 11))
                        .foregroundColor(snapshot.phase == .failed ? CDPalette.coral : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !compact {
                    actions
                }
            }
        }
        .padding(compact ? CDSpacing.m : CDSpacing.l)
        .cdGlass(radius: CDRadius.medium)
        .accessibilityElement(children: .contain)
    }

    private var statusLabel: some View {
        HStack(spacing: 4) {
            if snapshot.phase == .completed {
                Image(systemName: "checkmark.circle.fill").foregroundColor(CDPalette.mint)
            } else if snapshot.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(CDPalette.coral)
            } else if !snapshot.phase.isFinished {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
            }
            Text(TransferText.status(snapshot))
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private var showsProgress: Bool {
        snapshot.phase == .transferring || (snapshot.phase == .preparing && snapshot.totalBytes > 0)
    }

    private var hasProblem: Bool {
        snapshot.phase == .failed || snapshot.phase == .rejected
            || (snapshot.phase == .cancelled && snapshot.error?.fromPeer == true)
    }

    private var fileSummary: String {
        let names = snapshot.files.map { $0.name }
        let first = names.first ?? ""
        let rest = names.count > 1 ? " and \(names.count - 1) more" : ""
        return "\(first)\(rest) · \(Format.bytes(snapshot.totalBytes))"
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
                Button("Show in Finder") {
                    model.reveal(snapshot.files.compactMap { $0.savedURL })
                }
                .buttonStyle(GlassButtonStyle())
            }
            if model.canRetry(item) {
                Button("Try Again") { model.retry(item) }
                    .buttonStyle(GlassButtonStyle())
            }
            if snapshot.phase.isFinished {
                Button("Dismiss") { model.dismiss(item) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(.top, 2)
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CDSpacing.m) {
                SectionHeader(title: "This session",
                              detail: model.transfers.isEmpty ? nil : "Finished transfers are also saved to History")
                if model.transfers.isEmpty {
                    StateMessage(symbol: "arrow.up.arrow.down.circle",
                                 title: "No transfers yet",
                                 message: "Files you send or receive appear here with live progress.")
                        .cdGlass(radius: CDRadius.medium)
                } else {
                    ForEach(model.transfers) { item in
                        TransferCard(item: item)
                    }
                }
            }
            .padding(CDSpacing.xl)
        }
    }
}
