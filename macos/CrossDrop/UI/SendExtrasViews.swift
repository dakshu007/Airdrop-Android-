import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

// Send page extras: photo from the phone (§9.7), the send-when-nearby queue, the
// "Auto-delete after 24 h" switch (§9.8) and the shared expiry wording.

// MARK: - Expiry wording

enum ExpiryText {
    /// 86 400 → "24 h", 7 200 → "2 h", 1 800 → "30 min".
    static func duration(_ seconds: Int64) -> String {
        if seconds >= 3600 {
            let hours = Int((Double(seconds) / 3600).rounded())
            return "\(hours) h"
        }
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        return "\(minutes) min"
    }

    /// What the sender asked for: "Auto-deletes 24 h after arrival".
    static func request(_ seconds: Int64) -> String {
        "Auto-deletes \(duration(seconds)) after arrival"
    }
}

/// Small timer label for expiring drops: "⏱ Deletes Nov 23, 10:42".
struct ExpiryLabel: View {
    let text: String
    var done = false
    @Environment(\.cdScale) private var ui

    var body: some View {
        HStack(spacing: ui(4)) {
            Image(systemName: done ? "trash" : "timer")
                .font(ui.system(9.5, .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(ui.font(10.5, .medium))
                .lineLimit(1)
        }
        .foregroundColor(done ? CDPalette.textTertiary : CDPalette.amber)
        .padding(.horizontal, ui(8))
        .padding(.vertical, ui(3))
        .background(Capsule().fill(done ? Color.white.opacity(0.7) : Color(hex: 0xFFF6E0)))
        .overlay(Capsule().strokeBorder(done ? CDPalette.controlBorder : Color(hex: 0xF0DFB0), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Auto-delete switch

/// "Auto-delete after 24 h" for the next files send. Resets after each send.
struct AutoDeleteToggle: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    var body: some View {
        Toggle(isOn: $model.autoDeleteNextSend) {
            HStack(alignment: .top, spacing: ui(10)) {
                Image(systemName: "timer")
                    .font(ui.system(14, .semibold))
                    .foregroundColor(model.autoDeleteNextSend ? CDPalette.amber : CDPalette.textTertiary)
                    .frame(width: ui(30))
                    .padding(.top, ui(1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ui(2)) {
                    Text("Auto-delete after 24 h")
                        .font(ui.font(12.5, .medium))
                        .foregroundColor(CDPalette.textPrimary)
                    Text("Asks the receiving device to delete these files 24 hours after they arrive. The other device does the deleting, and its owner can keep them.")
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(GlassToggleStyle())
        .help("Applies to the next send only")
    }
}

// MARK: - Photo from the phone

/// "Take Photo / Pick Photo" with a paired phone, and the waiting state while the phone
/// answers. The photo lands on this Mac's clipboard.
struct PhoneCaptureCard: View {
    @EnvironmentObject private var model: AppModel
    /// The menu bar panel's slimmer version.
    var compact = false
    @Environment(\.cdScale) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let capture = model.capture {
                status(capture)
            } else if let phone = model.capturePhone {
                idle(phone)
            }
        }
        .padding(compact ? ui.m : ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
        .animation(CDMotion.layout(reduceMotion), value: model.capture)
        .accessibilityElement(children: .contain)
    }

    // MARK: Idle

    @ViewBuilder
    private func idle(_ phone: DiscoveredDevice) -> some View {
        if compact {
            HStack(spacing: ui.s) {
                badge(symbol: "camera.fill", tint: CDPalette.sky, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Photo from phone")
                        .font(ui.font(12, .semibold))
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                    Text(phone.name)
                        .font(ui.font(10.5))
                        .foregroundColor(CDPalette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { model.requestCapture(.photo, from: phone) } label: {
                    Image(systemName: "camera")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Take a photo with \(phone.name) (⇧⌘P)")
                .accessibilityLabel("Take photo with \(phone.name)")
                Button { model.requestCapture(.pick, from: phone) } label: {
                    Image(systemName: "photo.on.rectangle")
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .help("Pick a photo on \(phone.name)")
                .accessibilityLabel("Pick photo from \(phone.name)")
            }
        } else {
            VStack(alignment: .leading, spacing: ui.m) {
                HStack(alignment: .top, spacing: ui.m) {
                    badge(symbol: "camera.fill", tint: CDPalette.sky, size: 42)
                    VStack(alignment: .leading, spacing: ui(3)) {
                        Text("Photo from your phone")
                            .font(ui.headline)
                            .foregroundColor(CDPalette.textPrimary)
                        Text("Take or pick one on \(phone.name). It comes straight to this Mac's clipboard, ready to paste.")
                            .font(ui.callout)
                            .foregroundColor(CDPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: ui.s) {
                    Button { model.requestCapture(.photo, from: phone) } label: {
                        HStack(spacing: ui(8)) {
                            Label("Take Photo", systemImage: "camera")
                            Text("⇧⌘P").foregroundColor(Color(hex: 0xA8B8AE))
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityLabel("Take photo with \(phone.name)")
                    Button { model.requestCapture(.pick, from: phone) } label: {
                        Label("Pick Photo", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .accessibilityLabel("Pick photo from \(phone.name)")
                    if model.capturePhones.count > 1 {
                        Text("Other phones: right-click them under Nearby.")
                            .font(ui.caption)
                            .foregroundColor(CDPalette.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Request in progress

    @ViewBuilder
    private func status(_ capture: CaptureState) -> some View {
        switch capture.phase {
        case .asking, .waiting:
            waiting(capture)
        case .needsReceiving:
            problem(capture, symbol: "moon.zzz.fill", tint: CDPalette.amber) {
                Button("Allow My Devices") { model.allowCaptureReplies() }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Turns receiving on for your paired devices only, then asks the phone")
                Button("Cancel") { model.cancelCapture() }
                    .buttonStyle(GlassButtonStyle())
            }
        case .failed:
            problem(capture, symbol: "exclamationmark.triangle.fill", tint: CDPalette.coral) {
                Button("Try Again") { retry(capture) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Dismiss") { model.cancelCapture() }
                    .buttonStyle(GlassButtonStyle())
            }
        }
    }

    private func waiting(_ capture: CaptureState) -> some View {
        let size: CGFloat = compact ? 40 : 60
        return HStack(alignment: .center, spacing: ui.m) {
            ZStack {
                // Rings pulse only while connecting (a few seconds); while the phone's owner
                // takes the photo they stand still, so nothing animates for minutes.
                RadarView(active: capture.phase == .asking)
                    .frame(width: ui(size), height: ui(size))
                Image(systemName: capture.kind == .photo ? "camera.fill" : "photo.fill")
                    .font(ui.system(size * 0.3, .semibold))
                    .foregroundColor(.white)
                    .frame(width: ui(size * 0.55), height: ui(size * 0.55))
                    .background(Circle().fill(CDPalette.ink))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(capture.title)
                    .font(compact ? ui.font(12, .semibold) : ui.headline)
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                Text(capture.statusText)
                    .font(compact ? ui.caption : ui.callout)
                    .foregroundColor(CDPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if capture.phase == .waiting {
                    TimelineView(.periodic(from: capture.startedAt, by: 1)) { context in
                        Text("Waiting \(Self.elapsed(from: capture.startedAt, to: context.date)) · gives up after 10 min")
                            .font(ui.font(10.5).monospacedDigit())
                            .foregroundColor(CDPalette.textTertiary)
                            .lineLimit(1)
                    }
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(compact ? "Stop" : "Stop Waiting") { model.cancelCapture() }
                .buttonStyle(GlassButtonStyle(destructive: true))
                .accessibilityLabel("Stop waiting for \(capture.deviceName)")
        }
    }

    private func problem<Buttons: View>(_ capture: CaptureState, symbol: String, tint: Color,
                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: compact ? ui.s : ui.m) {
            HStack(alignment: .top, spacing: ui.m) {
                badge(symbol: symbol, tint: tint, size: compact ? 28 : 42)
                VStack(alignment: .leading, spacing: ui(2)) {
                    Text(capture.title)
                        .font(compact ? ui.font(12, .semibold) : ui.headline)
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                    Text(capture.statusText)
                        .font(compact ? ui.caption : ui.callout)
                        .foregroundColor(CDPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: ui.s) { buttons() }
        }
    }

    private func badge(symbol: String, tint: Color, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(ui.system(size * 0.4, .semibold))
            .foregroundColor(tint)
            .frame(width: ui(size), height: ui(size))
            .background(Circle().fill(CDPalette.mintSoft))
            .accessibilityHidden(true)
    }

    private func retry(_ capture: CaptureState) {
        let device = model.nearby.first { $0.deviceId == capture.deviceId }
        model.requestCapture(capture.kind, from: device)
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Send when nearby

/// Sends waiting for a paired device to come back. Delivery is event-driven (the device
/// shows up, wake, a network change); "Try Now" makes one attempt each.
struct SendQueueCard: View {
    @EnvironmentObject private var model: AppModel
    var compact = false
    @Environment(\.cdScale) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let queue = compact ? Array(model.sendQueue.prefix(3)) : model.sendQueue
        VStack(alignment: .leading, spacing: compact ? ui.s : ui(6)) {
            HStack(spacing: ui.s) {
                if compact {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(ui.system(12, .semibold))
                        .foregroundColor(CDPalette.mint)
                        .accessibilityHidden(true)
                    Text("Waiting to send")
                        .font(ui.font(12.5, .semibold))
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    SectionHeader(title: "Waiting to send", detail: "Delivers when the device is nearby")
                }
                Button("Try Now") { model.retryQueueNow() }
                    .buttonStyle(GlassButtonStyle())
                    .help("Try each waiting send once now")
            }
            VStack(spacing: 0) {
                ForEach(queue) { item in
                    QueueRow(item: item, compact: compact,
                             delivering: model.deliveringQueueIds.contains(item.id))
                    if item.id != queue.last?.id {
                        GlassDivider().padding(.leading, ui(compact ? 28 : 36) + ui.m)
                    }
                }
            }
            if compact, model.sendQueue.count > queue.count {
                Text("+\(model.sendQueue.count - queue.count) more in CrossDrop")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textTertiary)
            }
            if !compact {
                Text("CrossDrop tries when the device shows up nearby, when it sends you something, after this Mac wakes and when the network changes. It doesn't keep checking in the background. Files are sent from where they are now.")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, ui(4))
            }
        }
        .padding(.horizontal, compact ? ui.m : ui(CDLayout.cardPadding))
        .padding(.top, compact ? ui.m : ui(CDLayout.cardPadding - 2))
        .padding(.bottom, compact ? ui(6) : ui(CDLayout.cardPadding - 4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: CDRadius.card)
        .animation(CDMotion.layout(reduceMotion), value: model.sendQueue)
        .accessibilityElement(children: .contain)
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var model: AppModel
    let item: QueuedSend
    let compact: Bool
    let delivering: Bool
    @Environment(\.cdScale) private var ui

    var body: some View {
        HStack(spacing: ui.m) {
            ZStack(alignment: .bottomTrailing) {
                DeviceAvatar(platform: item.platform, size: compact ? 28 : 36)
                Image(systemName: "clock.fill")
                    .font(ui.system(compact ? 8 : 9, .bold))
                    .foregroundColor(CDPalette.amber)
                    .background(Circle().fill(Color.white).padding(-ui(1.5)))
                    .offset(x: ui(3), y: ui(3))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ui(2)) {
                Text(title)
                    .font(ui.font(compact ? 11.5 : 13, .medium))
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: ui(6)) {
                    Text(subtitle)
                        .font(ui.caption)
                        .foregroundColor(CDPalette.textTertiary)
                        .lineLimit(1)
                    if !compact, let seconds = item.expiresAfter {
                        ExpiryLabel(text: ExpiryText.request(seconds))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if delivering {
                HStack(spacing: ui(6)) {
                    ProgressView().controlSize(.small).scaleEffect(0.65 * ui.factor)
                        .frame(width: ui(14), height: ui(14))
                    Text("Sending…")
                        .font(ui.font(11, .medium))
                        .foregroundColor(CDPalette.textSecondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    model.cancelQueued(item)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle(size: compact ? 22 : 26))
                .help("Don't send this")
                .accessibilityLabel("Cancel sending \(title) to \(item.deviceName)")
            }
        }
        .padding(.vertical, ui(compact ? 6 : 10))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch item.offerKind {
        case .link: return item.text ?? "Link"
        case .text: return "Some text"
        case .files:
            guard let first = item.files.first?.name else { return item.summary }
            return item.files.count > 1 ? "\(first) + \(item.files.count - 1) more" : first
        }
    }

    private var subtitle: String {
        var parts = ["For \(item.deviceName)"]
        parts.append("added \(item.createdAt.formatted(.relative(presentation: .named)))")
        if item.attempts > 0 {
            parts.append(item.attempts == 1 ? "tried once" : "tried \(item.attempts) times")
        }
        return parts.joined(separator: " · ")
    }
}

/// Paired devices that aren't around: deliver what's selected when they come back.
struct DeliverLaterRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui

    /// Permanently paired devices not found by discovery right now (remembered ones too).
    static func awayDevices(_ model: AppModel) -> [TrustedDeviceRecord] {
        let live = Set(model.nearby.filter { !$0.isRemembered }.map { $0.deviceId })
        return model.trustedDevices.filter { !$0.isTemporary && !live.contains($0.deviceId) }
    }

    var body: some View {
        let away = Array(Self.awayDevices(model).prefix(6))
        VStack(alignment: .leading, spacing: ui.s) {
            GlassDivider()
                .padding(.bottom, ui(4))
            HStack(spacing: ui(6)) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(ui.system(11, .semibold))
                    .foregroundColor(CDPalette.mint)
                    .accessibilityHidden(true)
                Text("Not nearby? Deliver when they're back:")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowRow(spacing: ui(6)) {
                ForEach(away) { record in
                    Button {
                        model.queueSelection(for: record)
                    } label: {
                        Label(record.name, systemImage: record.platform == "macos" ? "laptopcomputer" : "iphone.gen3")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Send to \(record.name) as soon as it's nearby")
                    .accessibilityLabel("Deliver to \(record.name) when nearby")
                }
            }
        }
    }
}

/// Children left to right, wrapping onto new lines when the width runs out.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
