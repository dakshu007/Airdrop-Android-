import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
#if canImport(CrossDropCore)
import CrossDropCore
#endif

/// Drip Island: while files are dragged anywhere on the Mac, a glass shelf drops in at the
/// top centre of the screen with the pointer. Drop on a device bubble to send there, or on
/// the Shelf bubble to keep the files for later. It hides as soon as the drag ends.
///
/// How it notices a drag: a global monitor for left-mouse-dragged / mouse-up events (mouse
/// monitors need no permission) compares the system drag pasteboard's change count, at most
/// ~12 times a second and only while the mouse button is held. Nothing runs while idle.
/// The panel never takes focus from the app being dragged from.
final class DripIslandController {
    static let panelSize = NSSize(width: 680, height: 230)

    private let model: AppModel
    private let state = DripIslandState()
    private var panel: NSPanel?
    private var monitor: Any?
    private var subscriptions = Set<AnyCancellable>()
    private var lastDragChange: Int
    private var lastCheck: TimeInterval = 0
    /// This mouse gesture already turned out to be (or not to be) a file drag.
    private var gestureDecided = false
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var releaseTimer: Timer?
    private var discovering = false

    init(model: AppModel) {
        self.model = model
        lastDragChange = NSPasteboard(name: .drag).changeCount
        state.onDropped = { [weak self] feedback in self?.didDrop(feedback) }
        model.$dripIslandEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled { self?.install() } else { self?.uninstall() }
            }
            .store(in: &subscriptions)
    }

    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: Watching for drags

    private func install() {
        guard monitor == nil else { return }
        lastDragChange = NSPasteboard(name: .drag).changeCount
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func uninstall() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        showWork?.cancel()
        showWork = nil
        hideNow()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            guard !gestureDecided, !state.visible, showWork == nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastCheck >= 0.08 else { return }
            lastCheck = now
            let pasteboard = NSPasteboard(name: .drag)
            let count = pasteboard.changeCount
            // Unchanged: not a drag (yet); window moves and selections never touch it.
            guard count != lastDragChange else { return }
            lastDragChange = count
            gestureDecided = true
            guard Self.carriesFiles(pasteboard) else { return }
            scheduleShow()
        case .leftMouseUp:
            gestureDecided = false
            showWork?.cancel()
            showWork = nil
            if state.visible, state.feedback == nil { scheduleHide(after: 0.35) }
        default:
            break
        }
    }

    private static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private static var mouseIsDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    // MARK: Showing and hiding

    /// A short pause first, so a quick flick of a file in Finder doesn't flash the island.
    private func scheduleShow() {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.showWork = nil
            guard Self.mouseIsDown, self.model.dripIslandEnabled else { return }
            self.show(near: NSEvent.mouseLocation)
        }
        showWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func show(near point: NSPoint) {
        hideWork?.cancel()
        hideWork = nil
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = Self.panelSize
        // Just below the menu bar (and the notch, which sits inside it).
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        let origin = NSPoint(x: (screen.frame.midX - size.width / 2).rounded(),
                             y: (screen.frame.maxY - menuBar - 6 - size.height).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        state.feedback = nil
        panel.orderFrontRegardless()
        state.visible = true
        if !discovering {
            discovering = true
            model.beginDiscovery()
        }
        startReleaseWatch()
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideNow() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func hideNow() {
        hideWork?.cancel()
        hideWork = nil
        releaseTimer?.invalidate()
        releaseTimer = nil
        guard state.visible || panel?.isVisible == true else { return }
        state.visible = false
        // Let the exit animation play, then take the panel off screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, !self.state.visible else { return }
            self.panel?.orderOut(nil)
            self.state.feedback = nil
        }
        if discovering {
            discovering = false
            model.endDiscovery()
        }
    }

    /// Backstop for a drag that ends where the mouse-up isn't reported (cancelled with Esc,
    /// dropped on another app): checks the button state twice a second, only while shown.
    private func startReleaseWatch() {
        releaseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !Self.mouseIsDown, self.state.feedback == nil, self.hideWork == nil {
                self.gestureDecided = false
                self.scheduleHide(after: 0.3)
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    /// Something was dropped on the island: confirm briefly, then hide.
    private func didDrop(_ feedback: IslandFeedback) {
        gestureDecided = false
        state.feedback = feedback
        scheduleHide(after: 1.3)
    }

    private func makePanel() -> NSPanel {
        let panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.title = "Drip Island"
        let root = DripIslandView(state: state)
            .environmentObject(model)
            .environment(\.cdScale, CDScale())
            .environment(\.colorScheme, .light)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}

/// Borderless panel that never becomes key or main, so the app being dragged from keeps focus.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What the island shows after a drop.
struct IslandFeedback: Equatable {
    let id = UUID()
    let symbol: String
    let text: String
}

final class DripIslandState: ObservableObject {
    @Published var visible = false
    @Published var feedback: IslandFeedback?
    /// Set by the controller; called on the main thread after a drop.
    var onDropped: ((IslandFeedback) -> Void)?
}

// MARK: - Views (drawn at 100 %)

struct DripIslandView: View {
    @ObservedObject var state: DripIslandState
    @EnvironmentObject private var model: AppModel
    @Environment(\.cdScale) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Five device bubbles plus the Shelf fit the panel: 6 × 86 + 5 × 14 + 2 × 22 = 630 pt of
    /// 680, leaving room for the glass shadow. "+N more" covers the rest.
    static let maxBubbles = 5

    var body: some View {
        VStack(spacing: 0) {
            island
                .scaleEffect(state.visible || reduceMotion ? 1 : 0.86, anchor: .top)
                .offset(y: state.visible || reduceMotion ? 0 : -ui(18))
                .opacity(state.visible ? 1 : 0)
            Spacer(minLength: 0)
        }
        .padding(.top, ui(6))
        .frame(width: DripIslandController.panelSize.width, height: DripIslandController.panelSize.height, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 0.78),
                   value: state.visible)
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : CDMotion.quick, value: state.feedback)
        // Devices arriving or leaving while the island is open slide in and out of the row.
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : CDMotion.quick, value: devices.map { $0.deviceId })
    }

    private var island: some View {
        VStack(spacing: ui(10)) {
            if let feedback = state.feedback {
                feedbackRow(feedback)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
            } else {
                header
                HStack(alignment: .top, spacing: ui(14)) {
                    if devices.isEmpty {
                        searching
                    } else {
                        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                            IslandDeviceBubble(device: device,
                                               favorite: isFavorite(device),
                                               paired: model.isTrusted(device.deviceId),
                                               inRoom: model.room(for: device) != nil) { providers in
                                drop(providers, on: device)
                            }
                            .modifier(IslandStagger(index: index, visible: state.visible))
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    IslandShelfBubble(items: model.shelf) { providers in
                        stash(providers)
                    }
                    .modifier(IslandStagger(index: devices.count, visible: state.visible))
                }
            }
        }
        .padding(.horizontal, ui(22))
        .padding(.top, ui(12))
        .padding(.bottom, ui(14))
        .frame(minWidth: ui(300))
        .background(IslandGlass(cornerRadius: ui(30)))
        // Dropping on the glass between bubbles stashes too.
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            stash(providers)
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drip Island")
    }

    private var header: some View {
        HStack(spacing: ui(8)) {
            Image(systemName: "drop.fill")
                .font(ui.system(11, .semibold))
                .foregroundColor(CDPalette.mint)
                .accessibilityHidden(true)
            Text(devices.isEmpty ? "Drop on the Shelf to keep for later" : "Drop on a device to send, or on the Shelf to keep")
                .font(ui.font(12, .medium))
                .foregroundColor(CDPalette.textSecondary)
                .lineLimit(1)
            if hiddenCount > 0 {
                Chip(text: "+\(hiddenCount) more in CrossDrop")
            }
        }
    }

    private var searching: some View {
        HStack(spacing: ui(10)) {
            DripView(pose: .searching, size: 52, motion: .still)
            VStack(alignment: .leading, spacing: ui(2)) {
                Text("Looking for nearby devices")
                    .font(ui.font(13, .semibold))
                    .foregroundColor(CDPalette.textPrimary)
                Text(model.networkAvailable ? "Open CrossDrop on your phone and turn on Receiving."
                                            : "Not connected to Wi-Fi.")
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: ui(230), alignment: .leading)
        }
        .frame(height: ui(86))
    }

    private func feedbackRow(_ feedback: IslandFeedback) -> some View {
        HStack(spacing: ui(12)) {
            Image(systemName: feedback.symbol)
                .font(ui.system(20, .semibold))
                .foregroundColor(.white)
                .frame(width: ui(40), height: ui(40))
                .background(Circle().fill(CDPalette.mint))
                .accessibilityHidden(true)
            Text(feedback.text)
                .font(ui.font(14, .semibold))
                .foregroundColor(CDPalette.textPrimary)
                .lineLimit(2)
        }
        .padding(.vertical, ui(8))
        .accessibilityElement(children: .combine)
    }

    // MARK: Content

    /// My phones first, then paired, then room members, then everyone else.
    private var sortedDevices: [DiscoveredDevice] {
        func rank(_ device: DiscoveredDevice) -> Int {
            if isFavorite(device) { return 0 }
            if model.isTrusted(device.deviceId) { return 1 }
            if model.room(for: device) != nil { return 2 }
            return 3
        }
        return model.nearby.enumerated()
            .sorted { lhs, rhs in
                let a = rank(lhs.element), b = rank(rhs.element)
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    private var devices: [DiscoveredDevice] { Array(sortedDevices.prefix(Self.maxBubbles)) }

    private var hiddenCount: Int { max(0, model.nearby.count - Self.maxBubbles) }

    /// A paired phone (especially one marked "mine") swells a little, ready to catch the drop.
    private func isFavorite(_ device: DiscoveredDevice) -> Bool {
        device.platform == "android" && model.isTrusted(device.deviceId)
    }

    private func drop(_ providers: [NSItemProvider], on device: DiscoveredDevice) {
        model.send(providers: providers, to: device)
        state.onDropped?(IslandFeedback(symbol: "paperplane.fill", text: "Sending to \(device.name)"))
    }

    private func stash(_ providers: [NSItemProvider]) {
        model.stash(providers: providers)
        state.onDropped?(IslandFeedback(symbol: "tray.and.arrow.down.fill", text: "Kept on the Shelf"))
    }
}

/// Bubbles pop in one after another each time the island drops down; a plain fade with
/// Reduce Motion. Only runs as the island appears, so nothing animates while it rests.
private struct IslandStagger: ViewModifier {
    let index: Int
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(visible || reduceMotion ? 1 : 0.55)
            .opacity(visible ? 1 : 0)
            .animation(reduceMotion
                       ? .easeInOut(duration: 0.15)
                       : .spring(response: 0.42, dampingFraction: 0.68).delay(visible ? 0.06 + Double(index) * 0.035 : 0),
                       value: visible)
    }
}

/// One nearby device. Swells and glows while files hover over it.
struct IslandDeviceBubble: View {
    let device: DiscoveredDevice
    /// A paired phone: slightly larger, with a soft standing glow.
    let favorite: Bool
    let paired: Bool
    let inRoom: Bool
    let onDrop: ([NSItemProvider]) -> Void

    @State private var targeted = false
    @Environment(\.cdScale) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let size: CGFloat = favorite ? 60 : 52
        let glow = targeted ? 0.8 : (favorite ? 0.38 : 0)
        VStack(spacing: ui(6)) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [CDPalette.mintLight.opacity(glow), CDPalette.mintLight.opacity(0)],
                                         center: .center, startRadius: ui(size * 0.3), endRadius: ui(size * 0.95)))
                    .frame(width: ui(size * 1.9), height: ui(size * 1.9))
                    .allowsHitTesting(false)
                Circle()
                    .fill(LinearGradient(colors: [Color.white, targeted ? Color(hex: 0xD9F5C4) : CDPalette.mintSoft],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().strokeBorder(targeted ? CDPalette.mint : Color.white, lineWidth: targeted ? 2 : 1))
                    .shadow(color: CDPalette.shadow.opacity(targeted ? 0.3 : 0.14), radius: ui(targeted ? 12 : 6), x: 0, y: ui(3))
                    .frame(width: ui(size), height: ui(size))
                Image(systemName: device.platform == "macos" ? "laptopcomputer" : "iphone.gen3")
                    .font(ui.system(size * 0.4, .medium))
                    .foregroundColor(targeted ? CDPalette.mint : CDPalette.sky)
                if paired || inRoom {
                    Image(systemName: paired ? "checkmark.seal.fill" : "person.2.fill")
                        .font(ui.system(paired ? 13 : 10, .bold))
                        .foregroundColor(paired ? CDPalette.mint : CDPalette.sky)
                        .padding(ui(paired ? 1 : 4))
                        .background(Circle().fill(Color.white))
                        .offset(x: ui(size * 0.36), y: ui(size * 0.36))
                }
            }
            .frame(width: ui(66), height: ui(66))
            .scaleEffect(targeted && !reduceMotion ? 1.16 : 1)
            VStack(spacing: ui(1)) {
                Text(device.name)
                    .font(ui.font(11.5, .semibold))
                    .foregroundColor(CDPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(ui.font(10))
                    .foregroundColor(CDPalette.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: ui(86))
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            onDrop(providers)
            return true
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.6), value: targeted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Send to \(device.name)")
        .accessibilityValue(subtitle)
    }

    private var subtitle: String {
        if device.isRemembered { return "Last seen here" }
        if paired { return "Paired" }
        if inRoom { return "In your room" }
        return "Asks to pair"
    }
}

/// The Shelf: keeps dropped files for later. Shows the newest items fanned out.
struct IslandShelfBubble: View {
    let items: [ShelfItem]
    let onDrop: ([NSItemProvider]) -> Void

    @State private var targeted = false
    @Environment(\.cdScale) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let preview = Array(items.prefix(3))
        VStack(spacing: ui(6)) {
            ZStack {
                RoundedRectangle(cornerRadius: ui(18), style: .continuous)
                    .fill(targeted ? Color(hex: 0xEAF8EE) : Color.white.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: ui(18), style: .continuous)
                            .strokeBorder(targeted ? CDPalette.mint : CDPalette.controlBorder,
                                          style: StrokeStyle(lineWidth: targeted ? 2 : 1.2, dash: [ui(5), ui(4)]))
                    )
                    .frame(width: ui(60), height: ui(60))
                if preview.isEmpty {
                    Image(systemName: "tray.and.arrow.down")
                        .font(ui.system(22, .medium))
                        .foregroundColor(targeted ? CDPalette.mint : CDPalette.textSecondary)
                } else {
                    ForEach(Array(preview.enumerated()), id: \.element.id) { index, item in
                        FileIcon(url: item.url, name: item.name, size: 30)
                            .rotationEffect(.degrees(Double(index - 1) * 9))
                            .offset(x: ui(CGFloat(index - 1) * 7))
                    }
                }
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(ui.font(10, .bold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, ui(6))
                        .padding(.vertical, ui(2))
                        .background(Capsule().fill(CDPalette.ink))
                        .offset(x: ui(24), y: -ui(24))
                }
            }
            .frame(width: ui(66), height: ui(66))
            .scaleEffect(targeted && !reduceMotion ? 1.12 : 1)
            VStack(spacing: ui(1)) {
                Text("Shelf")
                    .font(ui.font(11.5, .semibold))
                    .foregroundColor(CDPalette.textPrimary)
                Text("Keep for later")
                    .font(ui.font(10))
                    .foregroundColor(CDPalette.textTertiary)
            }
            .frame(width: ui(86))
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            onDrop(providers)
            return true
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.65), value: targeted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shelf")
        .accessibilityValue(items.isEmpty ? "Empty" : Format.files(items.count))
        .accessibilityHint("Drop files here to keep them for later")
    }
}

/// Liquid Glass for a panel floating over any wallpaper: a real behind-window blur, a
/// white tint, a specular sheen across the top, a bright rim and a soft drop shadow.
struct IslandGlass: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            BehindWindowBlur(cornerRadius: cornerRadius)
            shape.fill(Color.white.opacity(0.55))
            shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.7), location: 0),
                                              .init(color: Color.white.opacity(0), location: 0.45)],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(LinearGradient(colors: [Color.white, Color.white.opacity(0.55)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: CDPalette.shadow.opacity(0.22), radius: 22, x: 0, y: 10)
        .accessibilityHidden(true)
    }
}

/// NSVisualEffectView blurring what is behind the window, clipped to a rounded rectangle.
struct BehindWindowBlur: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)
        view.maskImage = Self.mask(cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.maskImage = Self.mask(cornerRadius)
    }

    /// A stretchable rounded-rectangle mask.
    private static func mask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
