import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MintCanvas(mood: model.activeTransfers.isEmpty ? .idle : .active) {
            ZStack {
                HStack(alignment: .top, spacing: CDSpacing.l) {
                    Sidebar()
                        .frame(width: 224)
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(14)

                PromptLayer()
            }
            .overlay(alignment: .bottom) { NoticeToast() }
            .overlay(alignment: .bottomTrailing) { CelebrationCard() }
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear { model.beginDiscovery() }
        .onDisappear { model.endDiscovery() }
    }

    @ViewBuilder
    private var page: some View {
        ZStack {
            switch model.selectedTab {
            case .send: SendView()
            case .receive: ReceiveView()
            case .devices: DevicesView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .id(model.selectedTab)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
    }
}

/// Scrollable page body with consistent margins.
struct PageScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CDSpacing.l) {
                content
            }
            .padding(.top, 30)
            .padding(.bottom, CDSpacing.xl)
            .padding(.trailing, 4)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text("CrossDrop")
                    .font(CDFont.poppins(18, .bold))
                    .foregroundColor(CDPalette.textPrimary)
            }
            .legibleText()
            .padding(.top, 38) // clears the window buttons, which sit on the glass
            .padding(.horizontal, 8)
            .padding(.bottom, 18)

            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(CDMotion.layout(reduceMotion)) { model.selectedTab = tab }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 20)
                        Text(tab.title)
                            .font(CDFont.poppins(13.5, model.selectedTab == tab ? .semibold : .medium))
                        Spacer(minLength: 0)
                        if let count = badge(for: tab), count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(CDPalette.mint))
                        }
                    }
                }
                .buttonStyle(SidebarRowStyle(selected: model.selectedTab == tab, namespace: selection,
                                             reduceMotion: reduceMotion))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
            }

            Spacer(minLength: CDSpacing.l)
            ReceivingPill()
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: CDRadius.panel)
    }

    private func badge(for tab: AppTab) -> Int? {
        switch tab {
        case .send: return model.activeTransfers.filter { $0.snapshot.direction == .outgoing }.count
        case .receive: return model.activeTransfers.filter { $0.snapshot.direction == .incoming }.count
        default: return nil
        }
    }
}

/// 42pt row: ink pill when selected (slides between rows), white on hover,
/// green ring on keyboard focus.
struct SidebarRowStyle: ButtonStyle {
    let selected: Bool
    let namespace: Namespace.ID
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected, namespace: namespace, reduceMotion: reduceMotion)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let namespace: Namespace.ID
        let reduceMotion: Bool
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: CDRadius.row, style: .continuous)
            configuration.label
                .foregroundColor(selected ? .white : Color(hex: 0x2B3D33))
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(
                    ZStack {
                        if selected {
                            shape.fill(CDPalette.ink)
                                .matchedGeometryEffect(id: "sidebar.selection", in: namespace)
                        } else if hovering || configuration.isPressed {
                            shape.fill(Color.white.opacity(configuration.isPressed ? 0.9 : 0.6))
                        }
                    }
                )
                .contentShape(shape)
                .onHover { value in
                    if reduceMotion {
                        hovering = value
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) { hovering = value }
                    }
                }
                .modifier(FocusRing(shape: shape))
        }
    }
}

/// Bottom of the sidebar: whether this Mac can receive right now, with its switch.
struct ReceivingPill: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Toggle(isOn: Binding(get: { model.receivingEnabled }, set: { model.setReceiving($0) })) {
            HStack(spacing: 8) {
                StatusDot(color: ReceiverText.color(model.receiverStatus))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.receivingEnabled ? "Receiving" : "Not receiving")
                        .font(CDFont.poppins(12.5, .semibold))
                        .foregroundColor(CDPalette.textPrimary)
                    Text(ReceiverText.detail(model))
                        .font(CDFont.poppins(11))
                        .foregroundColor(CDPalette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .toggleStyle(GlassToggleStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 16, style: .inset)
        .accessibilityLabel("Receiving. \(ReceiverText.detail(model))")
    }
}

enum ReceiverText {
    static func color(_ status: ReceiverStatus) -> Color {
        switch status {
        case .ready: return CDPalette.mint
        case .starting: return CDPalette.amber
        case .off: return Color(hex: 0x9AA8A0)
        case .noNetwork, .localNetworkDenied, .failed: return CDPalette.coral
        }
    }

    static func detail(_ model: AppModel) -> String {
        switch model.receiverStatus {
        case .ready: return "Visible as \(model.deviceName)"
        case .starting: return "Starting…"
        case .off: return "Nearby devices can't send to you"
        case .noNetwork: return "Waiting for Wi-Fi"
        case .localNetworkDenied: return "Local Network access needed"
        case .failed(let message): return message
        }
    }
}

// MARK: - Prompts

/// Pairing and incoming-offer prompts: a glass card over a frosted, softly dimmed window.
struct PromptLayer: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let prompt = model.prompts.first {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Color(hex: 0x0F1D16, opacity: 0.12)
                }
                .ignoresSafeArea()
                .transition(.opacity)
                .accessibilityHidden(true)

                PromptCard(prompt: prompt)
                    .frame(width: 460)
                    .id(prompt.id)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(CDMotion.layout(reduceMotion), value: model.prompts.first?.id)
    }
}

// MARK: - Celebration

/// Drip pops in with confetti when files are verified; fades away by itself.
struct CelebrationCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let celebration = model.celebration {
                HStack(spacing: CDSpacing.m) {
                    ZStack {
                        ConfettiBurst()
                        DripView(pose: .done, size: 96, motion: .pop)
                    }
                    .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("All done!")
                            .font(CDFont.poppins(20, .bold))
                            .foregroundColor(CDPalette.textPrimary)
                        Text(celebration.message)
                            .font(CDFont.callout)
                            .foregroundColor(CDPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        model.celebration = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .padding(.vertical, 10)
                .frame(width: 380)
                .glassPanel(cornerRadius: 24)
                .padding(22)
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                .id(celebration.id)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("All done. \(celebration.message)")
            }
        }
        .animation(CDMotion.layout(reduceMotion), value: model.celebration)
    }
}

// MARK: - Toast

struct NoticeToast: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = model.notice {
                HStack(spacing: CDSpacing.m) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(CDPalette.mint)
                    Text(notice.text)
                        .font(CDFont.callout)
                        .foregroundColor(CDPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: 520)
                .glassPanel(cornerRadius: 18)
                .padding(.bottom, 22)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .id(notice.id)
            }
        }
        .animation(CDMotion.layout(reduceMotion), value: model.notice)
    }
}

// MARK: - Shared text

/// User-facing text for transfer states and errors.
enum TransferText {
    static func status(_ snapshot: TransferSnapshot) -> String {
        let outgoing = snapshot.direction == .outgoing
        switch snapshot.phase {
        case .preparing: return "Preparing…"
        case .connecting: return "Connecting…"
        case .pairing: return "Confirm the pairing code"
        case .waitingForAcceptance: return "Waiting for \(snapshot.peerName) to accept"
        case .awaitingApproval: return "Waiting for your approval"
        case .transferring: return outgoing ? "Sending" : "Receiving"
        case .completed: return outgoing ? "Delivered" : "Received and verified"
        case .failed: return "Failed"
        case .cancelled: return snapshot.error?.fromPeer == true ? "Cancelled by \(snapshot.peerName)" : "Cancelled"
        case .rejected: return outgoing ? "Declined" : "You declined"
        }
    }

    static func errorMessage(_ snapshot: TransferSnapshot) -> String {
        if snapshot.phase == .rejected {
            switch snapshot.rejectReason ?? "declined" {
            case "insufficient_storage": return "\(snapshot.peerName) doesn't have enough free space."
            case "timeout": return "\(snapshot.peerName) didn't respond in time."
            case "busy": return "\(snapshot.peerName) is busy. Try again in a moment."
            case "not_receiving": return "Receiving is turned off on \(snapshot.peerName)."
            default: return snapshot.direction == .outgoing ? "\(snapshot.peerName) declined the files." : "You declined these files."
            }
        }
        guard let error = snapshot.error else { return "" }
        return message(for: error, peer: snapshot.peerName)
    }

    static func message(for error: CrossDropError, peer: String) -> String {
        switch error.code {
        case ErrorCode.unreachable:
            return "Couldn't reach \(peer). Check that both devices are on the same Wi-Fi and that Receiving is on there. Guest networks often block devices from seeing each other."
        case ErrorCode.connectionLost: return "The connection to \(peer) was lost."
        case ErrorCode.timeout: return "\(peer) stopped responding."
        case ErrorCode.integrityFailed: return "A file didn't match its checksum and was discarded. Try sending again."
        case ErrorCode.insufficientStorage: return "There isn't enough free space to save these files."
        case ErrorCode.storageError: return "The files couldn't be saved. Check the destination folder in Settings."
        case ErrorCode.pairingRejected:
            return error.fromPeer ? "Pairing was declined on \(peer)." : "Pairing was cancelled."
        case ErrorCode.pairingRequired: return "\(peer) needs to pair with this Mac first."
        case ErrorCode.authFailed: return "The devices couldn't verify each other, so nothing was sent."
        case ErrorCode.peerChangedIdentity:
            return "\(peer)'s identity changed since you paired. If you reinstalled CrossDrop there, forget it in Devices and pair again."
        case ErrorCode.busy: return "\(peer) is busy with other transfers. Try again in a moment."
        case ErrorCode.notReceiving: return "Receiving is turned off on \(peer)."
        case ErrorCode.fileUnreadable: return "A file couldn't be read. It may have been moved or deleted."
        case ErrorCode.unsupportedVersion: return "\(peer) runs a CrossDrop version this Mac can't talk to. Update both apps."
        case ErrorCode.cancelled: return error.fromPeer ? "\(peer) cancelled the transfer." : "You cancelled the transfer."
        default: return "Something went wrong (\(error.code))."
        }
    }
}
