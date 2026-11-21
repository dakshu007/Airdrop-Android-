import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var zoom = UIZoom.shared

    var body: some View {
        // The window size sets the UI scale: larger windows (maximised, full screen)
        // draw everything larger instead of leaving the UI small in a sea of mint.
        GeometryReader { proxy in
            let scale = CDScale.forWindow(proxy.size, zoom: zoom.level)
            WindowContent(scale: scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .environment(\.cdScale, scale)
        }
        .ignoresSafeArea()
        .frame(minWidth: CDLayout.minWindow.width, minHeight: CDLayout.minWindow.height)
        .onAppear { model.beginDiscovery() }
        .onDisappear { model.endDiscovery() }
    }
}

/// Sidebar and page, with prompts, toasts and the celebration above them.
private struct WindowContent: View {
    let scale: CDScale
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ui = scale
        let prompting = !model.prompts.isEmpty
        MintCanvas(mood: model.activeTransfers.isEmpty ? .idle : .active) {
            ZStack {
                HStack(alignment: .top, spacing: 0) {
                    Sidebar()
                        .frame(width: ui(CDLayout.sidebarWidth))
                        .padding(.top, CDLayout.chromeTop)
                        .padding(.leading, ui(CDLayout.windowInset))
                        .padding(.bottom, ui(CDLayout.windowInset))
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                // Soften the window behind a prompt (a real blur of the content, so no
                // grey material tint).
                .blur(radius: prompting ? ui(8) : 0)
                .animation(CDMotion.layout(reduceMotion), value: prompting)

                PromptLayer()
            }
            .overlay(alignment: .bottom) { NoticeToast() }
            .overlay(alignment: .bottomTrailing) { CelebrationCard() }
        }
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

/// Scrollable page body: a centred column (wider on large windows), with insets wide
/// enough that card shadows and focus rings are never clipped. The scroll view runs to
/// the window's top, right and bottom edges, and content fades out softly at the top
/// and bottom instead of being cut at a hard line.
struct PageScroll<Content: View>: View {
    /// The page has a two-column layout for wide windows.
    let allowsWide: Bool
    let content: Content
    @Environment(\.cdScale) private var ui

    init(allowsWide: Bool = false, @ViewBuilder content: () -> Content) {
        self.allowsWide = allowsWide
        self.content = content()
    }

    var body: some View {
        let column = allowsWide && ui.wide ? CDLayout.wideColumn : CDLayout.column
        ScrollView {
            VStack(alignment: .leading, spacing: ui(CDLayout.cardGap)) {
                content
            }
            .frame(maxWidth: ui(column), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, CDLayout.chromeTop + ui(CDLayout.titleTop))
            .padding(.bottom, ui(CDLayout.pageBottom))
            .padding(.horizontal, ui(CDLayout.pageInset))
        }
        .scrollIndicators(.never)
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0), Color.black], startPoint: .top, endPoint: .bottom)
                    .frame(height: CDLayout.chromeTop)
                Rectangle().fill(Color.black)
                LinearGradient(colors: [Color.black, Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: ui(CDLayout.pageBottom) * 0.6)
            }
        )
        .ignoresSafeArea()
    }
}

/// Two equal columns for wide windows.
struct TwoColumns<Leading: View, Trailing: View>: View {
    let leading: Leading
    let trailing: Trailing
    @Environment(\.cdScale) private var ui

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: ui(CDLayout.cardGap)) {
            VStack(alignment: .leading, spacing: ui(CDLayout.cardGap)) { leading }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: ui(CDLayout.cardGap)) { trailing }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: ui(4)) {
            HStack(spacing: ui(10)) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: ui(30), height: ui(30))
                    .accessibilityHidden(true)
                Text("CrossDrop")
                    .font(ui.font(18, .bold))
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .legibleText()
            .padding(.top, ui(CDLayout.brandTop))
            .padding(.horizontal, ui(SidebarRowStyle.inset))
            .padding(.bottom, ui(16))

            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(CDMotion.layout(reduceMotion)) { model.selectedTab = tab }
                } label: {
                    HStack(spacing: ui(12)) {
                        Image(systemName: tab.symbol)
                            .font(ui.system(15, .medium))
                            .frame(width: ui(20))
                        Text(tab.title)
                            .font(ui.font(13.5, model.selectedTab == tab ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let count = badge(for: tab), count > 0 {
                            Text("\(count)")
                                .font(ui.system(10, .bold).monospacedDigit())
                                .foregroundColor(.white)
                                .padding(.horizontal, ui(6))
                                .padding(.vertical, ui(2))
                                .background(Capsule().fill(CDPalette.mint))
                        }
                    }
                }
                .buttonStyle(SidebarRowStyle(selected: model.selectedTab == tab, namespace: selection,
                                             reduceMotion: reduceMotion))
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
            }

            Spacer(minLength: ui.l)
            ReceivingPill()
        }
        .padding(ui(CDLayout.sidebarPadding))
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
    /// Leading inset of row content; the brand row and the receiving pill use it too,
    /// so icons, the logo and the status dot share one edge.
    static let inset: CGFloat = 12

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
        @Environment(\.cdScale) private var ui
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: ui(CDRadius.row), style: .continuous)
            configuration.label
                .foregroundColor(selected ? .white : Color(hex: 0x2B3D33))
                .padding(.horizontal, ui(SidebarRowStyle.inset))
                .frame(height: ui(42))
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
    @Environment(\.cdScale) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: ui(10)) {
            HStack(alignment: .top, spacing: ui(8)) {
                StatusDot(color: ReceiverText.color(model.receiverStatus))
                    .padding(.top, ui(5))
                VStack(alignment: .leading, spacing: ui(1)) {
                    Text(title)
                        .font(ui.font(12.5, .semibold))
                        .foregroundColor(CDPalette.textPrimary)
                        .lineLimit(1)
                    Text(ReceiverText.detail(model))
                        .font(ui.font(11))
                        .foregroundColor(CDPalette.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            ReceiveModePicker(compact: true)
        }
        .padding(.horizontal, ui(SidebarRowStyle.inset))
        .padding(.vertical, ui(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 16, style: .inset)
    }

    private var title: String {
        switch model.receiveMode {
        case .off: return "Not receiving"
        case .mine: return "My devices"
        case .everyone: return "Everyone"
        }
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
        case .ready:
            return model.receiveMode == .mine ? "Ready for your devices · invisible to others" : "Visible as \(model.deviceName)"
        case .starting: return "Starting…"
        case .off: return "Nearby devices can't send to you"
        case .noNetwork: return "Waiting for Wi-Fi"
        case .localNetworkDenied: return "Local Network access needed"
        case .failed(let message): return message
        }
    }
}

// MARK: - Prompts

/// Pairing and incoming-offer prompts: a glass card over the softly blurred window.
/// Shrinks to fit short windows, and scrolls as a last resort.
struct PromptLayer: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.cdScale) private var ui

    var body: some View {
        let fitted = ui.fitting(height: 700)
        ZStack {
            if let prompt = model.prompts.first {
                ZStack {
                    Color.white.opacity(reduceTransparency ? 0.8 : 0.35)
                    CDPalette.ink.opacity(0.08)
                }
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .transition(.opacity)
                .accessibilityHidden(true)

                ViewThatFits(in: .vertical) {
                    card(prompt, scale: fitted)
                    ScrollView {
                        card(prompt, scale: fitted)
                            .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.automatic)
                }
                .id(prompt.id)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(CDMotion.layout(reduceMotion), value: model.prompts.first?.id)
    }

    private func card(_ prompt: PromptItem, scale: CDScale) -> some View {
        PromptCard(prompt: prompt)
            .frame(width: scale(460))
            .padding(.horizontal, scale(24))
            .padding(.top, CDLayout.chromeTop)
            .padding(.bottom, scale(24))
            .environment(\.cdScale, scale)
    }
}

// MARK: - Celebration

/// Drip pops in with confetti when files are verified; fades away by itself.
struct CelebrationCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui

    var body: some View {
        ZStack {
            if let celebration = model.celebration {
                HStack(spacing: ui.m) {
                    ZStack {
                        ConfettiBurst()
                        DripView(pose: .done, size: 96, motion: .pop)
                    }
                    .frame(width: ui(96), height: ui(96))
                    VStack(alignment: .leading, spacing: ui(4)) {
                        Text("All done!")
                            .font(ui.font(20, .bold))
                            .foregroundColor(CDPalette.textPrimary)
                        Text(celebration.message)
                            .font(ui.callout)
                            .foregroundColor(CDPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.celebration = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .accessibilityLabel("Dismiss")
                }
                .padding(.leading, ui(10))
                .padding(.trailing, ui(14))
                .padding(.vertical, ui(10))
                .frame(width: ui(380))
                .glassPanel(cornerRadius: 24, style: .floating)
                .padding(ui(CDLayout.pageInset))
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
    @Environment(\.cdScale) private var ui

    var body: some View {
        ZStack {
            if let notice = model.notice {
                HStack(spacing: ui.m) {
                    Image(systemName: "info.circle.fill")
                        .font(ui.system(14))
                        .foregroundColor(CDPalette.mint)
                    Text(notice.text)
                        .font(ui.callout)
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
                .padding(.leading, ui(16))
                .padding(.trailing, ui(10))
                .padding(.vertical, ui(10))
                .frame(maxWidth: ui(520))
                .glassPanel(cornerRadius: 18, style: .floating)
                .padding(.horizontal, ui(CDLayout.pageInset))
                .padding(.bottom, ui(CDLayout.pageInset))
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
