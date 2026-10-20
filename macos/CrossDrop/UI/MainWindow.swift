import SwiftUI
import AppKit
#if canImport(CrossDropCore)
import CrossDropCore
#endif

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            GlassBackdrop()
            VStack(spacing: 0) {
                HeaderBar()
                    .padding(.horizontal, CDSpacing.xl)
                    .padding(.top, 34)
                TabBar()
                    .padding(.horizontal, CDSpacing.xl)
                    .padding(.top, CDSpacing.l)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 780, minHeight: 600)
        .overlay(alignment: .bottom) { NoticeToast() }
        .sheet(item: $model.activePromptBinding) { prompt in
            PromptSheet(prompt: prompt)
                .environmentObject(model)
        }
        .onAppear { model.beginDiscovery() }
        .onDisappear { model.endDiscovery() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case .send: SendView()
        case .activity: ActivityView()
        case .devices: DevicesView()
        case .history: HistoryView()
        case .settings:
            ScrollView {
                SettingsView()
                    .frame(maxWidth: 640)
                    .padding(CDSpacing.xl)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: CDSpacing.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(CDPalette.brand)
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 38, height: 38)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("CrossDrop").font(.system(size: 20, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("Direct and encrypted, on your local network. No cloud, no account.")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .accessibilityElement(children: .combine)
            }
            Spacer()
            ReceiveToggle()
        }
    }
}

struct ReceiveToggle: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        HStack(spacing: CDSpacing.s) {
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.receivingEnabled ? "Receiving" : "Receiving off")
                    .font(.system(size: 12, weight: .semibold))
                if !compact {
                    Text(detail).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Toggle("Receiving", isOn: Binding(get: { model.receivingEnabled }, set: { model.setReceiving($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Receive files from nearby devices")
                .accessibilityValue(model.receivingEnabled ? "On" : "Off")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .cdGlass(radius: 14)
    }

    private var color: Color {
        switch model.receiverStatus {
        case .ready: return CDPalette.mint
        case .starting: return CDPalette.amber
        case .off: return Color.secondary.opacity(0.5)
        case .noNetwork, .localNetworkDenied, .failed: return CDPalette.coral
        }
    }

    private var detail: String {
        switch model.receiverStatus {
        case .ready: return "Visible as “\(model.deviceName)”"
        case .starting: return "Starting…"
        case .off: return "Nearby devices can't send to you"
        case .noNetwork: return "Waiting for Wi-Fi"
        case .localNetworkDenied: return "Local Network access needed"
        case .failed(let message): return message
        }
    }
}

struct TabBar: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    if reduceMotion {
                        model.selectedTab = tab
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { model.selectedTab = tab }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol)
                        Text(tab.title)
                        if tab == .activity, !model.activeTransfers.isEmpty {
                            Text("\(model.activeTransfers.count)")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(CDPalette.sky))
                                .foregroundColor(.white)
                        }
                    }
                    .font(.system(size: 12, weight: model.selectedTab == tab ? .semibold : .medium))
                    .foregroundColor(model.selectedTab == tab ? .primary : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        if model.selectedTab == tab {
                            Capsule()
                                .fill(Color.primary.opacity(0.09))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                                .matchedGeometryEffect(id: "tab", in: selection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(model.selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(4)
        .cdGlass(radius: 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NoticeToast: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let notice = model.notice {
                HStack(spacing: CDSpacing.s) {
                    Image(systemName: "info.circle.fill").foregroundColor(CDPalette.sky)
                    Text(notice.text).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 520)
                .cdGlass(radius: 16)
                .padding(.bottom, CDSpacing.l)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .id(notice.id)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.notice)
    }
}

/// Shared user-facing text for transfer states and errors.
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
        case .completed: return outgoing ? "Sent" : "Received and verified"
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
