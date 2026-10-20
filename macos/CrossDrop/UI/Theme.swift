import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Mint Air (design/canvas): a light, airy mint backdrop, white glass with a
// bright rim, dark ink type, a black pill for the main action, and Drip.

// MARK: - Tokens

enum CDRadius {
    static let row: CGFloat = 12
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
    static let coral = Color(hex: 0xC9573B)
    static let focus = Color(hex: 0x149A5B)
    static let hairline = Color(hex: 0xE1EEE5)

    static let textPrimary = ink
    static let textSecondary = Color(hex: 0x4B5B52)
    static let textTertiary = Color(hex: 0x5E6E65)
}

/// Poppins (bundled, OFL; registered at launch). Falls back to the system font if missing.
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
    /// Cards and panels: white glass with a soft green shadow.
    case regular
    /// Smaller elements on top of a panel (rows, fields, chips).
    case inset
    /// The selected item: solid ink.
    case selected
}

struct GlassPanel: ViewModifier {
    let radius: CGFloat
    let style: GlassStyle

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(background(shape))
            .overlay(
                shape.strokeBorder(Color.white.opacity(style == .selected ? 0.1 : 0.95), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: Color(hex: 0x185434, opacity: style == .regular ? 0.10 : 0), radius: 20, x: 0, y: 12)
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        switch style {
        case .regular:
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.white.opacity(0.62))
                shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.5), location: 0),
                                                  .init(color: Color.white.opacity(0), location: 0.45)],
                                          startPoint: .top, endPoint: .bottom))
            }
        case .inset:
            shape.fill(Color.white.opacity(0.82))
        case .selected:
            shape.fill(CDPalette.ink)
        }
    }
}

extension View {
    /// White glass over the mint backdrop.
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

        var body: some View {
            configuration.label
                .font(CDFont.poppins(large ? 14 : 13, .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, large ? 22 : 18)
                .frame(minHeight: large ? 44 : 34)
                .background(Capsule().fill(CDPalette.ink.opacity(configuration.isPressed ? 0.82 : 1)))
                .shadow(color: CDPalette.ink.opacity(isEnabled ? 0.22 : 0), radius: 12, x: 0, y: 8)
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
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(CDFont.poppins(12, .semibold))
                .foregroundColor(destructive ? CDPalette.coral : CDPalette.ink)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.6 : (hovering ? 1 : 0.85))))
                .overlay(Capsule().strokeBorder(Color(hex: 0xD5E7DB), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: Capsule().inset(by: -3)))
        }
    }
}

/// Round white glass icon button.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(CDPalette.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.6 : (hovering ? 1 : 0.8))))
                .overlay(Circle().strokeBorder(Color(hex: 0xD5E7DB), lineWidth: 1))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: Circle().inset(by: -3)))
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

        var body: some View {
            HStack(spacing: CDSpacing.m) {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? CDPalette.mint : Color(hex: 0xD5E2D9))
                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
                        .padding(2)
                }
                .frame(width: 40, height: 24)
                .animation(reduceMotion ? nil : CDMotion.quick, value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityAction { configuration.isOn.toggle() }
        }
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
/// All motion stops with Reduce Motion.
struct DripView: View {
    enum Motion { case bob, float, pop, still }

    let pose: DripPose
    var size: CGFloat = 200
    var motion: Motion = .bob
    var label: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .frame(width: size, height: size)
        .offset(y: motion == .bob ? (up ? -6 : 0) : motion == .float ? (up ? -10 : 0) : 0)
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
                    RoundedRectangle(cornerRadius: 3)
                        .fill(piece.2)
                        .frame(width: 9, height: 13)
                        .rotationEffect(.degrees(fired ? 260 : 0))
                        .offset(x: fired ? piece.0 : 0, y: fired ? piece.1 : 0)
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
    @State private var shown = false

    var body: some View {
        let digits = Array(code)
        HStack(spacing: 6) {
            ForEach(0..<digits.count, id: \.self) { index in
                if index == 3 { Spacer().frame(width: 8) }
                Text(String(digits[index]))
                    .font(CDFont.poppins(30, .bold).monospacedDigit())
                    .foregroundColor(CDPalette.ink)
                    .frame(width: 44, height: 58)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.95)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(hex: 0xD5E7DB), lineWidth: 1))
                    .shadow(color: Color(hex: 0x185434, opacity: 0.1), radius: 7, x: 0, y: 4)
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

/// Platform glyph on a soft mint tile.
struct DeviceAvatar: View {
    let platform: String?
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: platform == "macos" ? "laptopcomputer" : "iphone.gen3")
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundColor(CDPalette.sky)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(CDPalette.mintSoft))
            .accessibilityHidden(true)
    }
}

/// Finder icon for a file (or for its type when the file isn't on this Mac).
struct FileIcon: View {
    let url: URL?
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
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

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CDPalette.mint.opacity(0.14))
                Capsule()
                    .fill(LinearGradient(colors: [CDPalette.mintLight, tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, proxy.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CDSpacing.s) {
            Text(title)
                .font(CDFont.poppins(15, .semibold))
                .foregroundColor(CDPalette.textPrimary)
            if let detail = detail {
                Text(detail)
                    .font(CDFont.caption)
                    .foregroundColor(CDPalette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Large page title used at the top of each section.
struct PageTitle: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .bottom, spacing: CDSpacing.l) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(CDFont.largeTitle)
                    .foregroundColor(CDPalette.textPrimary)
                Text(subtitle)
                    .font(CDFont.poppins(14))
                    .foregroundColor(CDPalette.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let trailing = trailing { trailing }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small glass pill with a status dot: "● 2 devices nearby".
struct StatusPill: View {
    let text: String
    var dot: Color = CDPalette.mint

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).font(CDFont.poppins(12.5, .medium)).foregroundColor(Color(hex: 0x2B3D33))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.78)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
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

    var body: some View {
        VStack(spacing: CDSpacing.s) {
            if let pose = pose {
                DripView(pose: pose, size: 150, motion: .bob)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(tint)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(CDPalette.mintSoft))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(CDFont.poppins(16, .semibold))
                .foregroundColor(CDPalette.textPrimary)
            Text(message)
                .font(CDFont.callout)
                .foregroundColor(CDPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .padding(.vertical, CDSpacing.xl)
        .padding(.horizontal, CDSpacing.l)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

/// Small rounded label: "Paired", "2 files", "1.2 GB".
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = CDPalette.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol = symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(CDFont.poppins(11, .medium).monospacedDigit())
        }
        .foregroundColor(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Color(hex: 0xD5E7DB), lineWidth: 1))
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

/// Hairline divider for rows inside a glass panel.
struct GlassDivider: View {
    var body: some View {
        Rectangle().fill(CDPalette.hairline).frame(height: 1)
    }
}
