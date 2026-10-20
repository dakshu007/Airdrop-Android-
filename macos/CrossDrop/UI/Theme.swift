import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Tokens

enum CDRadius {
    static let row: CGFloat = 12
    static let card: CGFloat = 20
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

enum CDPalette {
    static let sky = Color(red: 0.42, green: 0.70, blue: 1.0)
    static let mint = Color(red: 0.38, green: 0.90, blue: 0.62)
    static let amber = Color(red: 1.0, green: 0.78, blue: 0.36)
    static let coral = Color(red: 1.0, green: 0.48, blue: 0.48)
    /// Keyboard focus ring (light blue, as in the design reference).
    static let focus = Color(red: 0.61, green: 0.78, blue: 1.0)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.5)
}

enum CDFont {
    static let largeTitle = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let headline = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let callout = Font.system(size: 12)
    static let caption = Font.system(size: 11)
}

enum CDMotion {
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.85)
    static let quick = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// Spring normally, a plain fade when Reduce Motion is on.
    static func layout(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : spring
    }
}

// MARK: - Wallpapers

enum Wallpaper: String, CaseIterable, Identifiable {
    case dusk, lagoon, canopy, midnight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dusk: return "Dusk Ridge"
        case .lagoon: return "Lagoon"
        case .canopy: return "Canopy"
        case .midnight: return "Midnight"
        }
    }

    var assetName: String { "Wallpaper-" + rawValue }

    /// Darkening over the whole wallpaper, for text contrast.
    var scrim: Double {
        switch self {
        case .dusk: return 0.14
        case .lagoon: return 0.12
        case .canopy: return 0.16
        case .midnight: return 0.04
        }
    }

    /// White frosting inside glass panels.
    var frost: Double {
        switch self {
        case .dusk: return 0.10
        case .lagoon: return 0.12
        case .canopy: return 0.09
        case .midnight: return 0.07
        }
    }

    /// Extra darkening inside glass on bright wallpapers so white text stays legible.
    var glassShade: Double {
        switch self {
        case .lagoon: return 0.12
        case .canopy: return 0.10
        case .dusk: return 0.08
        case .midnight: return 0.0
        }
    }
}

/// Loads wallpapers once and keeps a pre-blurred copy for glass panels.
final class WallpaperCache {
    static let shared = WallpaperCache()
    private var images: [Wallpaper: NSImage] = [:]
    private var blurred: [Wallpaper: NSImage] = [:]
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func image(_ wallpaper: Wallpaper) -> NSImage {
        if let cached = images[wallpaper] { return cached }
        let image = NSImage(named: wallpaper.assetName) ?? NSImage(size: NSSize(width: 16, height: 10))
        images[wallpaper] = image
        return image
    }

    /// The wallpaper downscaled and blurred (what a frosted pane "sees"). Same aspect ratio as the original,
    /// so it lines up exactly when laid out with the same scaledToFill frame.
    func blurredImage(_ wallpaper: Wallpaper) -> NSImage {
        if let cached = blurred[wallpaper] { return cached }
        let source = image(wallpaper)
        var result = source
        if let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let input = CIImage(cgImage: cg)
            let scale = 640.0 / max(input.extent.width, 1)
            let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blur = small.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14.0])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.18, kCIInputBrightnessKey: 0.03])
                .cropped(to: small.extent)
            if let out = context.createCGImage(blur, from: small.extent) {
                result = NSImage(cgImage: out, size: NSSize(width: small.extent.width, height: small.extent.height))
            }
        }
        blurred[wallpaper] = result
        return result
    }
}

/// What glass panels need to know to show the wallpaper behind them.
struct WallpaperContext {
    var wallpaper: Wallpaper = .dusk
    var canvasSize: CGSize = .zero
}

private struct WallpaperContextKey: EnvironmentKey {
    static let defaultValue = WallpaperContext()
}

extension EnvironmentValues {
    var wallpaperContext: WallpaperContext {
        get { self[WallpaperContextKey.self] }
        set { self[WallpaperContextKey.self] = newValue }
    }
}

/// Name of the coordinate space the wallpaper is laid out in.
enum WallpaperSpace {
    static let name = "cd.wallpaper"
}

/// Hosts a full-bleed wallpaper and lets every `glassPanel` inside align its frosted copy to it.
struct WallpaperCanvas<Content: View>: View {
    let wallpaper: Wallpaper
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                WallpaperImage(wallpaper: wallpaper, size: proxy.size, blurred: false)
                    .id(wallpaper)
                    .transition(.opacity)
                Color.black.opacity(wallpaper.scrim)
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .ignoresSafeArea()
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .coordinateSpace(name: WallpaperSpace.name)
            .environment(\.wallpaperContext, WallpaperContext(wallpaper: wallpaper, canvasSize: proxy.size))
            .animation(.easeInOut(duration: 0.6), value: wallpaper)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

/// The wallpaper laid out to fill `size` (centre crop). Blurred and sharp variants share this layout.
struct WallpaperImage: View {
    let wallpaper: Wallpaper
    let size: CGSize
    let blurred: Bool

    var body: some View {
        Image(nsImage: blurred ? WallpaperCache.shared.blurredImage(wallpaper) : WallpaperCache.shared.image(wallpaper))
            .resizable()
            .interpolation(blurred ? .medium : .high)
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
            .accessibilityHidden(true)
    }
}

/// The frosted wallpaper behind one glass panel, aligned with the canvas.
struct FrostedFill: View {
    @Environment(\.wallpaperContext) private var context

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(WallpaperSpace.name))
            WallpaperImage(wallpaper: context.wallpaper, size: context.canvasSize, blurred: true)
                .offset(x: -frame.minX, y: -frame.minY)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Glass

enum GlassStyle {
    /// Cards and panels.
    case regular
    /// Smaller elements on top of a panel (chips, rows, buttons): no extra blur, just light.
    case inset
    /// Darker selection pill, like the selected row in the reference.
    case selected
}

struct GlassPanel: ViewModifier {
    let radius: CGFloat
    let style: GlassStyle
    @Environment(\.wallpaperContext) private var context

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(background(shape))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(style == .selected ? 0.18 : 0.55),
                                            Color.white.opacity(style == .selected ? 0.06 : 0.14)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(style == .regular ? 0.25 : 0), radius: 24, x: 0, y: 12)
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        switch style {
        case .regular:
            ZStack {
                FrostedFill()
                Color.black.opacity(context.wallpaper.glassShade)
                Color.white.opacity(context.wallpaper.frost)
                LinearGradient(stops: [.init(color: Color.white.opacity(0.22), location: 0),
                                       .init(color: Color.white.opacity(0), location: 0.4)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipShape(shape)
        case .inset:
            ZStack {
                shape.fill(Color.white.opacity(0.08))
                shape.fill(LinearGradient(stops: [.init(color: Color.white.opacity(0.12), location: 0),
                                                  .init(color: Color.white.opacity(0), location: 0.5)],
                                          startPoint: .top, endPoint: .bottom))
            }
        case .selected:
            shape.fill(Color.black.opacity(0.55))
        }
    }
}

#if compiler(>=6.2)
extension View {
    /// Frosted glass over the wallpaper. On macOS 26 built with Xcode 26, regular panels use the
    /// system Liquid Glass material instead.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = CDRadius.card, style: GlassStyle = .regular) -> some View {
        if style == .regular {
            if #available(macOS 26.0, *) {
                self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                self.modifier(GlassPanel(radius: cornerRadius, style: style))
            }
        } else {
            self.modifier(GlassPanel(radius: cornerRadius, style: style))
        }
    }
}
#else
extension View {
    /// Frosted glass over the wallpaper.
    func glassPanel(cornerRadius: CGFloat = CDRadius.card, style: GlassStyle = .regular) -> some View {
        self.modifier(GlassPanel(radius: cornerRadius, style: style))
    }
}
#endif

extension View {
    /// Soft shadow that keeps white text readable over bright glass.
    func legibleText() -> some View {
        shadow(color: Color.black.opacity(0.28), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Focus

/// Light-blue 1.5pt ring when the control has keyboard focus.
struct FocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay(
            shape.strokeBorder(CDPalette.focus, lineWidth: isFocused ? 1.5 : 0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Buttons

/// White pill with dark text: the one obvious action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.black.opacity(0.85))
                .padding(.horizontal, 18)
                .frame(minHeight: 34)
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.8 : 0.95)))
                .shadow(color: Color.white.opacity(isEnabled ? 0.25 : 0), radius: 10, x: 0, y: 0)
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : CDMotion.quick, value: configuration.isPressed)
                .contentShape(Capsule())
                .modifier(FocusRing(shape: Capsule().inset(by: -3)))
        }
    }
}

/// Translucent pill for secondary actions.
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
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(destructive ? CDPalette.coral : .white)
                .padding(.horizontal, 14)
                .frame(minHeight: 30)
                .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.24 : (hovering ? 0.18 : 0.12))))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: Capsule().inset(by: -3)))
        }
    }
}

/// Round glass icon button.
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
                .foregroundColor(.white.opacity(0.9))
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.26 : (hovering ? 0.18 : 0.1))))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .modifier(FocusRing(shape: Circle().inset(by: -3)))
        }
    }
}

/// Glass switch matching the design (white knob on a frosted track, mint when on).
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
                    Capsule()
                        .fill(configuration.isOn ? CDPalette.mint.opacity(0.85) : Color.white.opacity(0.16))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                    Circle()
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.25), radius: 3, x: 0, y: 1)
                        .padding(3)
                }
                .frame(width: 46, height: 28)
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

// MARK: - Components

/// Platform glyph in a frosted circle.
struct DeviceAvatar: View {
    let platform: String?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.14))
            Circle().fill(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
            Image(systemName: platform == "macos" ? "laptopcomputer" : "iphone.gen3")
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
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

/// Thin white progress bar with a soft glow.
struct CapsuleProgress: View {
    let value: Double
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: max(5, proxy.size.width * CGFloat(min(max(value, 0), 1))))
                    .shadow(color: tint.opacity(0.7), radius: 6, x: 0, y: 0)
            }
        }
        .frame(height: 5)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(CDPalette.textPrimary)
            if let detail = detail {
                Text(detail)
                    .font(CDFont.caption)
                    .foregroundColor(CDPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .legibleText()
        .accessibilityAddTraits(.isHeader)
    }
}

/// Large page title used at the top of each section.
struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(CDFont.largeTitle)
                .foregroundColor(CDPalette.textPrimary)
            Text(subtitle)
                .font(CDFont.body)
                .foregroundColor(CDPalette.textSecondary)
        }
        .legibleText()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Icon + title + explanation, used for empty and problem states.
struct StateMessage: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .white

    var body: some View {
        VStack(spacing: CDSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundColor(tint.opacity(0.9))
                .frame(width: 52, height: 52)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .accessibilityHidden(true)
            Text(title)
                .font(CDFont.headline)
                .foregroundColor(.white)
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
        .legibleText()
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.8), radius: 4)
            .accessibilityHidden(true)
    }
}

/// Small rounded label: "Paired", "2 files", "1.2 GB".
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let symbol = symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .medium).monospacedDigit())
        }
        .foregroundColor(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(tint == .white ? 0.14 : 0.18)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1))
    }
}

/// Discovery animation: rings expanding from the centre, static when Reduce Motion is on.
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
                                .stroke(Color.white.opacity(0.5 * (1 - phase)), lineWidth: 1.2)
                                .scaleEffect(0.3 + phase * 0.7)
                        }
                    }
                }
            } else {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .stroke(Color.white.opacity(0.14 + Double(index) * 0.05), lineWidth: 1)
                        .scaleEffect(0.42 + Double(index) * 0.26)
                }
            }
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.white.opacity(0.16)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
        }
        .accessibilityHidden(true)
    }
}

/// Lightweight divider for rows inside a glass panel.
struct GlassDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
    }
}
