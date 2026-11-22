import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Mint Air (design/canvas): a light, airy mint backdrop, white glass with a
// bright rim, dark ink type, a black pill for the main action, and Drip.
//
// Every size in this file is a design value at 100 %. Views read the current
// `CDScale` from the environment (`@Environment(\.cdScale) private var ui`) and
// multiply through it: `ui(16)` for a length, `ui.body` / `ui.font(13)` for text,
// `ui.system(15)` for SF Symbols. Components (glass, buttons, Drip, avatars, icons,
// chips) scale their own sizes, so callers pass design values, never `ui(...)`.

// MARK: - Tokens

enum CDRadius {
    static let row: CGFloat = 12
    static let field: CGFloat = 12
    static let tile: CGFloat = 16
    static let card: CGFloat = 22
    static let panel: CGFloat = 28
}

enum CDSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// The page rhythm shared by every screen of the main window.
enum CDLayout {
    /// Room above the sidebar for the window's close/minimise/zoom buttons. System
    /// chrome doesn't scale, so this one stays in plain points.
    static let chromeTop: CGFloat = 32
    /// Sidebar distance from the window's left and bottom edges.
    static let windowInset: CGFloat = 14
    static let sidebarWidth: CGFloat = 224
    /// Space between the sidebar and the page column, and between the column and the
    /// window's right edge. Wide enough that card shadows are never cut off.
    static let pageInset: CGFloat = 24
    /// Sidebar padding and the brand row's top padding, used to line the page title up
    /// with the brand row.
    static let sidebarPadding: CGFloat = 10
    static let brandTop: CGFloat = 12
    /// Page title top, below `chromeTop`, so its line centres on the brand row.
    static let titleTop: CGFloat = 15
    /// Widest page column, single and two-column.
    static let column: CGFloat = 880
    static let wideColumn: CGFloat = 1240
    /// Page width (at 100 %) from which pages may show two columns.
    static let wideThreshold: CGFloat = 1100
    /// Space between cards, and the extra space under a page title.
    static let cardGap: CGFloat = 16
    static let titleGap: CGFloat = 8
    /// Inner padding of every card, and the vertical padding of a row inside one.
    static let cardPadding: CGFloat = 20
    static let rowPadding: CGFloat = 12
    static let pageBottom: CGFloat = 36

    static let defaultWindow = CGSize(width: 1040, height: 700)
    static let minWindow = CGSize(width: 900, height: 620)
    /// The smallest layout (at 100 %) every page is designed for; the scale never
    /// grows so far that the window holds less than this.
    static let minLogical = CGSize(width: 860, height: 540)

    /// Width a page column gets in a window of `logicalWidth` (at 100 %).
    static func pageWidth(forLogicalWidth logicalWidth: CGFloat) -> CGFloat {
        logicalWidth - windowInset - sidebarWidth - pageInset * 2
    }
}

// MARK: - Scale

/// How large the main window's UI is drawn. 1.0 at the default 1040×700 window; it
/// grows in proportion to the window up to 1.35 (maximised, full screen), times the
/// user's View › Zoom level. Fonts are re-laid out at the new size, so text stays crisp.
struct CDScale: Equatable {
    var factor: CGFloat = 1
    /// Width available to a page column, at 100 % (unscaled points).
    var pageWidth: CGFloat = CDLayout.pageWidth(forLogicalWidth: CDLayout.defaultWindow.width)
    /// The window's content size in points.
    var window: CGSize = CDLayout.defaultWindow

    /// Scales a design length, rounded to half a point so edges stay sharp.
    func callAsFunction(_ value: CGFloat) -> CGFloat {
        (value * factor * 2).rounded() / 2
    }

    /// Room for two columns on pages that offer them.
    var wide: Bool { pageWidth >= CDLayout.wideThreshold }

    // Spacing
    var xs: CGFloat { self(CDSpacing.xs) }
    var s: CGFloat { self(CDSpacing.s) }
    var m: CGFloat { self(CDSpacing.m) }
    var l: CGFloat { self(CDSpacing.l) }
    var xl: CGFloat { self(CDSpacing.xl) }
    var xxl: CGFloat { self(CDSpacing.xxl) }

    // Type
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        CDFont.poppins(size * factor, weight)
    }

    func system(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        Font.system(size: size * factor, weight: weight, design: design)
    }

    var display: Font { font(34, .bold) }
    var largeTitle: Font { font(30, .bold) }
    var title: Font { font(20, .bold) }
    var headline: Font { font(14, .semibold) }
    var body: Font { font(13) }
    var callout: Font { font(12) }
    var caption: Font { font(11) }

    /// Native controls (segmented pickers) only come in a few sizes.
    var controlSize: ControlSize { factor >= 1.2 ? .large : .regular }

    /// The same scale, shrunk if needed so something `height` points tall (at 100 %)
    /// fits the window: used by prompts and sheets.
    func fitting(height: CGFloat) -> CDScale {
        var copy = self
        let limit = window.height / max(height, 1)
        copy.factor = (max(min(factor, limit), 0.75) * 100).rounded() / 100
        return copy
    }

    /// The scale for a window of `size` at the user's zoom level.
    static func forWindow(_ size: CGSize, zoom: CGFloat) -> CDScale {
        guard size.width > 1, size.height > 1 else { return CDScale() }
        // Grows with the window relative to the default size (the tighter of the two
        // axes), from 1.0 at the default window up to 1.35, so a maximised laptop window
        // fills with UI instead of leaving wide margins of mint.
        let byWidth = size.width / CDLayout.defaultWindow.width
        let byHeight = size.height / CDLayout.defaultWindow.height
        let automatic = min(max(min(byWidth, byHeight), 1), 1.35)
        // Never so large that the window holds less than the smallest designed layout.
        let roomWidth = size.width / CDLayout.minLogical.width
        let roomHeight = size.height / CDLayout.minLogical.height
        var factor = min(automatic * zoom, roomWidth, roomHeight)
        factor = max(factor, 0.8)
        factor = (factor * 100).rounded() / 100
        return CDScale(factor: factor,
                       pageWidth: CDLayout.pageWidth(forLogicalWidth: size.width / factor),
                       window: size)
    }
}

private struct CDScaleKey: EnvironmentKey {
    static let defaultValue = CDScale()
}

extension EnvironmentValues {
    /// The UI scale. 1.0 unless the main window sets it (the menu bar panel stays at 1.0).
    var cdScale: CDScale {
        get { self[CDScaleKey.self] }
        set { self[CDScaleKey.self] = newValue }
    }
}

/// View › Zoom In / Zoom Out / Actual Size for the main window, remembered between launches.
final class UIZoom: ObservableObject {
    static let shared = UIZoom()
    static let minimum: CGFloat = 0.85
    static let maximum: CGFloat = 1.6
    private static let steps: [CGFloat] = [0.85, 0.92, 1.0, 1.1, 1.2, 1.32, 1.45, 1.6]

    @Published private(set) var level: CGFloat

    private init() {
        level = UIZoom.clamp(CGFloat(AppSettings.uiZoom))
    }

    var canZoomIn: Bool { level < UIZoom.maximum - 0.001 }
    var canZoomOut: Bool { level > UIZoom.minimum + 0.001 }

    func zoomIn() {
        set(UIZoom.steps.first(where: { $0 > level + 0.001 }) ?? UIZoom.maximum)
    }

    func zoomOut() {
        set(UIZoom.steps.last(where: { $0 < level - 0.001 }) ?? UIZoom.minimum)
    }

    func reset() {
        set(1)
    }

    private func set(_ value: CGFloat) {
        let clamped = UIZoom.clamp(value)
        guard abs(clamped - level) > 0.0001 else { return }
        level = clamped
        AppSettings.uiZoom = Double(clamped)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, minimum), maximum)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum CDPalette {
    /// Ink: titles, body text and the main action pill.
    static let ink = Color(hex: 0x0F1D16)
    /// Brand green for dots, switches, progress and success.
    static let mint = Color(hex: 0x149A5B)
    static let mintLight = Color(hex: 0x6FD493)
    /// Soft mint behind icons and the selected row.
    static let mintSoft = Color(hex: 0xE3F5E8)
    /// Links and secondary accents (darker green for contrast).
    static let sky = Color(hex: 0x0B6B3F)
    static let amber = Color(hex: 0xB07A00)
    /// Amber for small text on light fills (meets 4.5:1 where `amber` doesn't).
    static let amberText = Color(hex: 0x8A5F00)
    static let coral = Color(hex: 0xC9573B)
    static let focus = Color(hex: 0x149A5B)
    /// Row separators inside a card.
    static let hairline = Color(hex: 0xD6E7DC)
    /// Edge of fields, chips and small controls sitting on a card.
    static let controlBorder = Color(hex: 0xD5E7DB)
    /// Soft green of the glass shadows.
    static let shadow = Color(hex: 0x185434)

    static let textPrimary = ink
    static let textSecondary = Color(hex: 0x4B5B52)
    static let textTertiary = Color(hex: 0x5E6E65)
}

/// Poppins (bundled, OFL; registered at launch). Falls back to the system font if missing.
/// Sizes here are at 100 %; views use `CDScale.font(_:_:)` so text follows the UI scale.
enum CDFont {
    static func poppins(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .bold, .heavy, .black: face = "Poppins-Bold"
        case .semibold: face = "Poppins-SemiBold"
        case .medium: face = "Poppins-Medium"
        default: face = "Poppins-Regular"
        }
        return .custom(face, size: size)
    }

    static let display = poppins(34, .bold)
    static let largeTitle = poppins(30, .bold)
    static let title = poppins(20, .bold)
    static let headline = poppins(14, .semibold)
    static let body = poppins(13)
    static let callout = poppins(12)
    static let caption = poppins(11)
}

enum CDMotion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.85)
    static let quick = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// Spring normally, a plain fade when Reduce Motion is on.
    static func layout(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : spring
    }
}

// MARK: - Backdrop

/// The background follows the moment: mint when idle, lime while files move,
/// deeper green when they arrive, a warm blush on failure.
enum Mood: Equatable {
    case idle, active, done, failed

    var colors: [Color] {
        switch self {
        case .idle: return [Color(hex: 0xFFFFFF), Color(hex: 0xF1FAF3), Color(hex: 0xDAF1E1)]
        case .active: return [Color(hex: 0xFFFFFF), Color(hex: 0xF2FCE6), Color(hex: 0xD9F5C4)]
        case .done: return [Color(hex: 0xFFFFFF), Color(hex: 0xE6F7EA), Color(hex: 0xBFE8CB)]
        case .failed: return [Color(hex: 0xFFFFFF), Color(hex: 0xFBF5F1), Color(hex: 0xF1E4DC)]
        }
    }

    var sphere: [Color] {
        switch self {
        case .failed: return [Color(hex: 0xFBE3CF), Color(hex: 0xE8B08E), Color(hex: 0xC4785A)]
        default: return [Color(hex: 0xD8F7B4), Color(hex: 0x7FD99A), Color(hex: 0x2E9E66)]
        }
    }
}

/// A blurred, glowing sphere.
private struct GlowSphere: View {
    let colors: [Color]
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: colors, center: UnitPoint(x: 0.35, y: 0.3),
                                 startRadius: 0, endRadius: size * 0.6))
            .frame(width: size, height: size)
            .blur(radius: size * 0.13)
            .opacity(0.45)
    }
}

/// Full-bleed mint gradient with two drifting spheres (still with Reduce Motion).
struct MintBackdrop: View {
    var mood: Mood = .idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RadialGradient(colors: mood.colors, center: UnitPoint(x: 0.6, y: 0),
                               startRadius: 0, endRadius: max(size.width, size.height) * 0.95)
                GlowSphere(colors: mood.sphere, size: max(size.width, size.height) * 0.36)
                    .position(x: size.width + 30, y: size.height + 20)
                    .offset(x: drift ? -18 : 0, y: drift ? -22 : 0)
                GlowSphere(colors: [Color(hex: 0xEFFFD2), Color(hex: 0x9BE6A6), Color(hex: 0x3BAA70)],
                           size: max(size.width, size.height) * 0.16)
                    .position(x: size.width * 0.42, y: -10)
                    .offset(x: drift ? 14 : 0, y: drift ? 12 : 0)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .animation(.easeInOut(duration: 0.6), value: mood)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 5.2).repeatForever(autoreverses: true)) { drift = true }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Hosts a full-window mint backdrop behind its content.
struct MintCanvas<Content: View>: View {
    var mood: Mood = .idle
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            MintBackdrop(mood: mood)
            content
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Glass

enum GlassStyle {
    /// Cards and panels on the page: crisp white glass with a short, soft shadow.
    case regular
    /// Prompts, toasts and the celebration card, lifted above the page.
    case floating
    /// Smaller elements on top of a panel (rows, fields, chips).
    case inset
    /// The selected item: solid ink.
    case selected
}

/// A drop shadow drawn only outside `shape`, so it never shows through the translucent
/// glass above it (that show-through is what turned card bottoms grey).
private struct OuterShadow: View {
    let shape: RoundedRectangle
    let color: Color
    let radius: CGFloat
    let y: CGFloat

    var body: some View {
        let reach = radius * 2 + abs(y) + 4
        shape
            .fill(Color.white)
            .shadow(color: color, radius: radius, x: 0, y: y)
            .mask(
                ZStack {
                    Rectangle().padding(-reach)
                    shape.blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// White glass: a translucent white fill (no system material, which reads grey over
/// the mint), a 1 px bright inner rim, and a soft outer shadow on page cards.
/// `radius` is a design value; the panel scales it.
struct GlassPanel: ViewModifier {
    let radius: CGFloat
    let style: GlassStyle
    @Environment(\.cdScale) private var ui

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ui(radius), style: .continuous)
        return content
            .background(
                ZStack {
                    switch style {
                    case .regular:
                        OuterShadow(shape: shape, color: CDPalette.shadow.opacity(0.07), radius: ui(10), y: ui(4))
                    case .floating:
                        OuterShadow(shape: shape, color: CDPalette.shadow.opacity(0.16), radius: ui(26), y: ui(12))
                    case .inset, .selected:
                        EmptyView()
                    }
                    fill(shape)
                }
            )
            .overlay(
                shape.strokeBorder(borderColor, lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }

    private var borderColor: Color {
        switch style {
        case .regular, .floating: return Color.white.opacity(0.95)
        case .inset: return CDPalette.controlBorder
        case .selected: return Color.white.opacity(0.1)
        }
    }

    @ViewBuilder
    private func fill(_ shape: RoundedRectangle) -> some View {
        switch style {
        case .regular, .floating:
            ZStack {
                shape.fill(Color.white.opacity(style == .floating ? 0.9 : 0.74))
                // A soft specular sheen across the top.
                shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.45), location: 0),
                                                  .init(color: Color.white.opacity(0), location: 0.5)],
                                          startPoint: .top, endPoint: .bottom))
            }
        case .inset:
            shape.fill(Color.white.opacity(0.88))
        case .selected:
            shape.fill(CDPalette.ink)
        }
    }
}

extension View {
    /// White glass over the mint backdrop. `cornerRadius` is a design value (scaled).
    func glassPanel(cornerRadius: CGFloat = CDRadius.card, style: GlassStyle = .regular) -> some View {
        self.modifier(GlassPanel(radius: cornerRadius, style: style))
    }

    /// Kept for call sites from the wallpaper design; ink on mint needs no shadow.
    func legibleText() -> some View { self }
}

// MARK: - Focus

/// Green 2pt ring when the control has keyboard focus.
struct FocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay(
            shape.strokeBorder(CDPalette.focus, lineWidth: isFocused ? 2 : 0)
                .allowsHitTesting(false)
        )
    }
}

/// Border for a glass text field: mint while it's being typed in.
struct FieldFocusBorder: ViewModifier {
    let focused: Bool
    let radius: CGFloat
    @Environment(\.cdScale) private var ui

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: ui(radius), style: .continuous)
                .strokeBorder(CDPalette.focus.opacity(focused ? 0.9 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Buttons

/// Black pill with white text: the one obvious action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, large: large)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        let large: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.cdScale) private var ui

        var body: some View {
            configuration.label
                .font(ui.font(large ? 14 : 13, .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .padding(.horizontal, ui(large ? 22 : 18))
                .frame(minHeight: ui(large ? 44 : 34))
                .background(
                    Capsule()
                        .fill(CDPalette.ink.opacity(configuration.isPressed ? 0.82 : 1))
                        .shadow(color: CDPalette.ink.opacity(isEnabled ? 0.18 : 0), radius: ui(8), x: 0, y: ui(4))
                )
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : CDMotion.quick, value: configuration.isPressed)
                .contentShape(Capsule())
                .modifier(FocusRing(shape: Capsule().inset(by: -3)))
        }
    }
}

/// White glass pill for secondary actions.
struct GlassButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        GlassBody(configuration: configuration, destructive: destructive)
    }

    private struct GlassBody: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.cdScale) private var ui
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(ui.font(12, .semibold))
                .foregroundColor(destructive ? CDPalette.coral : CDPalette.ink)
                .lineLimit(1)
                .padding(.horizontal, ui(14))
                .frame(minHeight: ui(30))
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.6 : (hovering ? 1 : 0.85))))
                .overlay(Capsule().strokeBorder(CDPalette.controlBorder, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: Capsule().inset(by: -3)))
        }
    }
}

/// Round white glass icon button. `size` is a design value (scaled).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.cdScale) private var ui
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(ui.system(size * 0.42, .semibold))
                .foregroundColor(CDPalette.ink)
                .frame(width: ui(size), height: ui(size))
                .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.6 : (hovering ? 1 : 0.8))))
                .overlay(Circle().strokeBorder(CDPalette.controlBorder, lineWidth: 1))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: Circle().inset(by: -3)))
        }
    }
}

/// White tile that lifts slightly on hover.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.cdScale) private var ui

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: ui(CDRadius.tile), style: .continuous)
            configuration.label
                .background(
                    shape
                        .fill(Color.white.opacity(configuration.isPressed ? 0.7 : (hovering ? 1 : 0.86)))
                        .shadow(color: CDPalette.shadow.opacity(hovering ? 0.10 : 0.04),
                                radius: ui(hovering ? 8 : 4), x: 0, y: ui(hovering ? 3 : 1))
                )
                .overlay(shape.strokeBorder(hovering ? CDPalette.controlBorder : Color.white.opacity(0.95), lineWidth: 1))
                .contentShape(shape)
                .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
                .animation(reduceMotion ? nil : CDMotion.quick, value: hovering)
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: shape))
        }
    }
}

/// Switch: grey-green track when off, brand green when on, white knob.
struct GlassToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlassToggleBody(configuration: configuration)
    }

    private struct GlassToggleBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.cdScale) private var ui

        var body: some View {
            HStack(spacing: ui.l) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A real button, so the switch is reachable with Tab and Space and shows the
                // focus ring (a tap gesture alone can't take keyboard focus).
                Button {
                    configuration.isOn.toggle()
                } label: {
                    ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                        Capsule().fill(configuration.isOn ? CDPalette.mint : Color(hex: 0xD5E2D9))
                        Circle()
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                            .padding(ui(2))
                    }
                    .frame(width: ui(40), height: ui(24))
                    .animation(reduceMotion ? nil : CDMotion.quick, value: configuration.isOn)
                }
                .buttonStyle(SwitchTrackButtonStyle())
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAction { configuration.isOn.toggle() }
        }
    }
}

/// The switch track as a button: no chrome of its own, a press dim and the focus ring.
private struct SwitchTrackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
            .modifier(FocusRing(shape: Capsule().inset(by: -3)))
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? ""
    }

    static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    /// "309997" → "309 997"
    static func code(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return String(code.prefix(3)) + " " + String(code.suffix(3))
    }

    /// Groups a fingerprint into blocks of four for reading aloud.
    static func fingerprint(_ hex: String) -> String {
        var groups: [String] = []
        var current = ""
        for character in hex {
            current.append(character)
            if current.count == 4 {
                groups.append(current)
                current = ""
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.joined(separator: " ")
    }
}

// MARK: - Drip

/// Drip, the CrossDrop character (rendered by scripts/render_illustrations.py).
enum DripPose: String {
    case welcome, nearby, pairing, incoming, sending, done, sleepy, searching, nowifi, failed, mac

    var assetName: String { "Drip-" + rawValue }
    /// Same pose with the eyes closed, cross-faded in for a blink.
    var blinkAsset: String? { self == .welcome ? "Drip-welcome-blink" : nil }
}

/// Drip with gentle life: bobbing, the occasional blink, a pop-in for celebrations.
/// All motion stops with Reduce Motion. `size` is a design value (scaled).
struct DripView: View {
    enum Motion { case bob, float, pop, still }

    let pose: DripPose
    var size: CGFloat = 200
    var motion: Motion = .bob
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui
    @State private var up = false
    @State private var shown = false

    var body: some View {
        ZStack {
            image(pose.assetName)
            if let blink = pose.blinkAsset, !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.12)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5.2)
                    image(blink).opacity(t < 0.18 ? 1 : 0)
                }
            }
        }
        .frame(width: ui(size), height: ui(size))
        .offset(y: lift)
        .rotationEffect(.degrees(motion == .float ? (up ? 2 : -2) : 0))
        .scaleEffect(motion == .pop ? (shown ? 1 : 0.6) : 1)
        .opacity(motion == .pop ? (shown ? 1 : 0) : 1)
        .onAppear {
            guard !reduceMotion else {
                shown = true
                return
            }
            switch motion {
            case .bob:
                withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) { up = true }
            case .float:
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { up = true }
            case .pop:
                withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { shown = true }
            case .still:
                break
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
    }

    /// How far Drip rises at the top of a bob or float.
    private var lift: CGFloat {
        guard up else { return 0 }
        switch motion {
        case .bob: return -ui(6)
        case .float: return -ui(10)
        case .pop, .still: return 0
        }
    }

    private func image(_ name: String) -> some View {
        Image(name)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

/// One-shot confetti burst from the centre. Hidden with Reduce Motion.
struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui
    @State private var fired = false

    private let pieces: [(CGFloat, CGFloat, Color)] = [
        (-150, -150, CDPalette.mint), (140, -170, Color(hex: 0xF2C14E)), (-100, -210, Color(hex: 0x9BE6A6)),
        (100, -220, CDPalette.mint), (-170, -50, Color(hex: 0xF2C14E)), (170, -70, CDPalette.mintLight),
        (-40, -250, Color(hex: 0xF2C14E)), (40, -240, CDPalette.ink), (-190, -130, CDPalette.mintLight),
        (190, -130, Color(hex: 0x9BE6A6)),
    ]

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<pieces.count, id: \.self) { index in
                    let piece = pieces[index]
                    RoundedRectangle(cornerRadius: ui(3))
                        .fill(piece.2)
                        .frame(width: ui(9), height: ui(13))
                        .rotationEffect(.degrees(fired ? 260 : 0))
                        .offset(x: fired ? ui(piece.0) : 0, y: fired ? ui(piece.1) : 0)
                        .opacity(fired ? 0 : 1)
                        .animation(.timingCurve(0.15, 0.7, 0.3, 1, duration: 1.6).delay(Double(index) * 0.025), value: fired)
                }
            }
        }
        .onAppear { fired = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The pairing code as six white tiles (three, a gap, three) that flip in one by one.
struct CodeTiles: View {
    let code: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui
    @State private var shown = false

    var body: some View {
        let digits = Array(code)
        let tile = RoundedRectangle(cornerRadius: ui(14), style: .continuous)
        HStack(spacing: ui(6)) {
            ForEach(0..<digits.count, id: \.self) { index in
                if index == 3 { Spacer().frame(width: ui(8)) }
                Text(String(digits[index]))
                    .font(ui.font(30, .bold).monospacedDigit())
                    .foregroundColor(CDPalette.ink)
                    .frame(width: ui(44), height: ui(58))
                    .background(tile.fill(Color.white.opacity(0.95)))
                    .overlay(tile.strokeBorder(CDPalette.controlBorder, lineWidth: 1))
                    .shadow(color: CDPalette.shadow.opacity(0.08), radius: ui(5), x: 0, y: ui(3))
                    .rotation3DEffect(.degrees(shown ? 0 : -90), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                    .opacity(shown ? 1 : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.7).delay(Double(index) * 0.09),
                               value: shown)
            }
        }
        .onAppear { shown = true }
        .accessibilityElement()
        .accessibilityLabel("Pairing code \(digits.map { String($0) }.joined(separator: " "))")
    }
}

// MARK: - Components

/// Platform glyph on a soft mint tile. `size` is a design value (scaled).
struct DeviceAvatar: View {
    let platform: String?
    var size: CGFloat = 44
    @Environment(\.cdScale) private var ui

    var body: some View {
        Image(systemName: platform == "macos" ? "laptopcomputer" : "iphone.gen3")
            .font(ui.system(size * 0.42))
            .foregroundColor(CDPalette.sky)
            .frame(width: ui(size), height: ui(size))
            .background(RoundedRectangle(cornerRadius: ui(size * 0.3), style: .continuous).fill(CDPalette.mintSoft))
            .accessibilityHidden(true)
    }
}

/// Finder icon for a file (or for its type when the file isn't on this Mac).
/// `size` is a design value (scaled).
struct FileIcon: View {
    let url: URL?
    let name: String
    var size: CGFloat = 32
    @Environment(\.cdScale) private var ui

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: ui(size), height: ui(size))
            .accessibilityHidden(true)
    }

    private var icon: NSImage {
        if let url = url, FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let ext = (name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// Rounded green progress bar on a pale track.
struct CapsuleProgress: View {
    let value: Double
    var tint: Color = CDPalette.mint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CDPalette.mint.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [CDPalette.mintLight, tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(ui(8), proxy.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: ui(8))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String? = nil
    @Environment(\.cdScale) private var ui

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ui.s) {
            Text(title)
                .font(ui.font(15, .semibold))
                .foregroundColor(CDPalette.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = detail {
                Text(detail)
                    .font(ui.caption)
                    .foregroundColor(CDPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Large page title used at the top of each section. Carries the extra gap above the
/// first card, so every page starts the same way.
struct PageTitle: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil
    @Environment(\.cdScale) private var ui

    var body: some View {
        HStack(alignment: .bottom, spacing: ui.l) {
            VStack(alignment: .leading, spacing: ui(4)) {
                Text(title)
                    .font(ui.largeTitle)
                    .foregroundColor(CDPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(ui.font(14))
                    .foregroundColor(CDPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let trailing = trailing {
                trailing
                    .padding(.bottom, ui(2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, ui(CDLayout.titleGap))
    }
}

/// Small glass pill with a status dot: "● 2 devices nearby".
struct StatusPill: View {
    let text: String
    var dot: Color = CDPalette.mint
    @Environment(\.cdScale) private var ui

    var body: some View {
        HStack(spacing: ui(8)) {
            Circle().fill(dot).frame(width: ui(7), height: ui(7))
            Text(text)
                .font(ui.font(12.5, .medium))
                .foregroundColor(Color(hex: 0x2B3D33))
                .lineLimit(1)
        }
        .padding(.horizontal, ui(14))
        .padding(.vertical, ui(7))
        .background(Capsule().fill(Color.white.opacity(0.8)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Drip (or an icon) + title + explanation, used for empty and problem states.
struct StateMessage: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = CDPalette.sky
    var pose: DripPose? = nil
    @Environment(\.cdScale) private var ui

    var body: some View {
        VStack(spacing: ui.s) {
            if let pose = pose {
                DripView(pose: pose, size: 150, motion: .bob)
            } else {
                Image(systemName: symbol)
                    .font(ui.system(22))
                    .foregroundColor(tint)
                    .frame(width: ui(52), height: ui(52))
                    .background(RoundedRectangle(cornerRadius: ui(16), style: .continuous).fill(CDPalette.mintSoft))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(ui.font(16, .semibold))
                .foregroundColor(CDPalette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(ui.callout)
                .foregroundColor(CDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ui(420))
        }
        .padding(.vertical, ui.xl)
        .padding(.horizontal, ui(CDLayout.cardPadding))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let color: Color
    @Environment(\.cdScale) private var ui

    var body: some View {
        Circle().fill(color)
            .frame(width: ui(8), height: ui(8))
            .accessibilityHidden(true)
    }
}

/// Small rounded label: "Paired", "2 files", "1.2 GB".
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = CDPalette.textSecondary
    @Environment(\.cdScale) private var ui

    var body: some View {
        HStack(spacing: ui(4)) {
            if let symbol = symbol {
                Image(systemName: symbol).font(ui.system(9, .bold))
            }
            Text(text)
                .font(ui.font(11, .medium).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundColor(tint)
        .padding(.horizontal, ui(9))
        .padding(.vertical, ui(4))
        .background(Capsule().fill(Color.white.opacity(0.85)))
        .overlay(Capsule().strokeBorder(CDPalette.controlBorder, lineWidth: 1))
        .fixedSize()
    }
}

/// Discovery animation: green rings expanding from the centre, static with Reduce Motion.
struct RadarView: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            let phase = (time / 3.0 + Double(index) / 3.0).truncatingRemainder(dividingBy: 1.0)
                            Circle()
                                .stroke(CDPalette.mint.opacity(0.45 * (1 - phase)), lineWidth: 1.5)
                                .scaleEffect(0.3 + phase * 0.7)
                        }
                    }
                }
            } else {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(CDPalette.mint.opacity(0.12 + Double(index) * 0.05), lineWidth: 1)
                        .scaleEffect(0.42 + Double(index) * 0.26)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One-pixel separator between rows inside a glass panel.
struct GlassDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(CDPalette.hairline)
            .frame(height: 1 / max(displayScale, 1))
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// Glass segmented control for a handful of choices.
struct SegmentChoice: Identifiable {
    let id: Int
    let label: String
}

struct SegmentedGlass: View {
    let choices: [SegmentChoice]
    @Binding var selection: Int
    var accessibilityName: String = ""
    /// Stretch the segments to share the width offered (each keeps at least its
    /// label's width), instead of hugging the labels.
    var fillsWidth = false
    /// Smaller type and padding, for tight spots such as the sidebar.
    var compact = false
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cdScale) private var ui

    var body: some View {
        SegmentRow(spacing: ui(2)) {
            ForEach(choices) { choice in
                let selected = selection == choice.id
                Button {
                    withAnimation(CDMotion.layout(reduceMotion)) { selection = choice.id }
                } label: {
                    Text(choice.label)
                        .font(ui.font(compact ? 10.5 : 11, selected ? .semibold : .medium))
                        .foregroundColor(selected ? .white : CDPalette.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, ui(compact ? 6 : 10))
                        .frame(maxWidth: .infinity)
                        .frame(height: ui(compact ? 24 : 26))
                        .background {
                            if selected {
                                Capsule().fill(CDPalette.ink)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(SegmentButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(ui(3))
        .background(Capsule().fill(Color.white.opacity(0.85)))
        .overlay(Capsule().strokeBorder(CDPalette.controlBorder, lineWidth: 1))
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}

/// Segments in a row: each gets its label's width plus an equal share of any width
/// left over, so a filling control stays balanced without truncating long labels.
private struct SegmentRow: Layout {
    var spacing: CGFloat

    private func naturalWidths(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(.unspecified).width }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = naturalWidths(subviews)
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        let natural = widths.reduce(0, +) + gaps
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        var width = natural
        if let offered = proposal.width, offered.isFinite {
            width = max(offered, natural)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let widths = naturalWidths(subviews)
        let gaps = spacing * CGFloat(subviews.count - 1)
        let natural = widths.reduce(0, +) + gaps
        let extra = max(bounds.width - natural, 0) / CGFloat(subviews.count)
        var x = bounds.minX
        for index in subviews.indices {
            let width = widths[index] + extra
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY),
                                  anchor: .leading,
                                  proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// Plain segment with a focus ring for keyboard navigation.
private struct SegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .modifier(FocusRing(shape: Capsule()))
    }
}

/// A vertical scroll view exactly as tall as its content, up to `maxHeight`; past that it
/// scrolls. For sheets and the menu bar panel, which size to their content and would
/// otherwise grow past the window or screen and clip their bottom. The content is
/// measured, so the height is explicit rather than left to the scroll view's ideal size.
struct FittedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat? = nil

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FittedScrollHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: min(contentHeight ?? maxHeight, maxHeight))
        .onPreferenceChange(FittedScrollHeightKey.self) { height in
            // Whole points, so sub-point jitter can't start a layout loop.
            let rounded = height.rounded(.up)
            if contentHeight != rounded { contentHeight = rounded }
        }
    }
}

private struct FittedScrollHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
