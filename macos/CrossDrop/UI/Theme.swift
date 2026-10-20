import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum CDRadius {
    static let small: CGFloat = 12
    static let medium: CGFloat = 18
    static let large: CGFloat = 24
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
    static let sky = Color(red: 0.24, green: 0.56, blue: 1.0)
    static let violet = Color(red: 0.53, green: 0.39, blue: 0.98)
    static let teal = Color(red: 0.15, green: 0.76, blue: 0.80)
    static let mint = Color(red: 0.18, green: 0.74, blue: 0.48)
    static let amber = Color(red: 0.98, green: 0.66, blue: 0.20)
    static let coral = Color(red: 0.95, green: 0.33, blue: 0.33)

    static var brand: LinearGradient {
        LinearGradient(colors: [sky, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Soft, static colour field behind the glass so translucency has something to show.
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(red: 0.06, green: 0.07, blue: 0.11) : Color(red: 0.94, green: 0.95, blue: 0.98))
            Circle()
                .fill(CDPalette.sky.opacity(dark ? 0.32 : 0.30))
                .frame(width: 520, height: 520)
                .blur(radius: 130)
                .offset(x: -300, y: -240)
            Circle()
                .fill(CDPalette.violet.opacity(dark ? 0.28 : 0.22))
                .frame(width: 460, height: 460)
                .blur(radius: 130)
                .offset(x: 320, y: -60)
            Circle()
                .fill(CDPalette.teal.opacity(dark ? 0.20 : 0.20))
                .frame(width: 420, height: 420)
                .blur(radius: 130)
                .offset(x: -60, y: 320)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Translucent layered surface with a fine highlight edge and soft depth.
struct LegacyGlass: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        return content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    // Specular sheen across the top edge.
                    shape.fill(LinearGradient(colors: [Color.white.opacity(dark ? 0.07 : 0.32), Color.white.opacity(0)],
                                              startPoint: .top, endPoint: .center))
                }
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(dark ? 0.24 : 0.85), Color.white.opacity(dark ? 0.05 : 0.25)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
                .allowsHitTesting(false)
            )
            .shadow(color: Color.black.opacity(dark ? 0.30 : 0.07), radius: 18, x: 0, y: 8)
    }
}

#if compiler(>=6.2)
extension View {
    /// Liquid Glass on macOS 26 (public SwiftUI API), layered materials before that.
    @ViewBuilder
    func cdGlass(radius: CGFloat = CDRadius.medium) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.modifier(LegacyGlass(radius: radius))
        }
    }
}
#else
extension View {
    func cdGlass(radius: CGFloat = CDRadius.medium) -> some View {
        self.modifier(LegacyGlass(radius: radius))
    }
}
#endif

// MARK: - Buttons

/// Draws a visible keyboard-focus ring around custom-styled buttons.
private struct FocusRing<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay(
            shape.strokeBorder(Color.accentColor, lineWidth: isFocused ? 2.5 : 0)
                .padding(-4)
                .allowsHitTesting(false)
        )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(CDPalette.brand)
                        .overlay(Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.28), Color.white.opacity(0)],
                                                               startPoint: .top, endPoint: .center)))
                )
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.45)
                .shadow(color: CDPalette.sky.opacity(isEnabled ? 0.35 : 0), radius: 10, x: 0, y: 4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .contentShape(Capsule())
                .modifier(FocusRing(shape: Capsule()))
        }
    }
}

struct GlassButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, destructive: destructive)
    }

    private struct GlassButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(destructive ? CDPalette.coral : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(.thinMaterial))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(configuration.isPressed ? 0.25 : 0.12), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .modifier(FocusRing(shape: Capsule()))
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07)))
            .contentShape(Circle())
            .modifier(FocusRing(shape: Circle()))
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

// MARK: - Small components

struct DeviceAvatar: View {
    let platform: String?
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().fill(CDPalette.brand)
            Circle().fill(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
            Image(systemName: platform == "macos" ? "laptopcomputer" : "candybarphone")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

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

struct CapsuleProgress: View {
    let value: Double
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(CDPalette.brand))
                    .frame(width: max(6, proxy.size.width * CGFloat(min(max(value, 0), 1))))
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: value)
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15, weight: .semibold))
            if let detail = detail {
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
            }
            Spacer()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Icon + title + explanation, used for empty and problem states.
struct StateMessage: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .secondary

    var body: some View {
        VStack(spacing: CDSpacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .regular))
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .padding(.vertical, CDSpacing.l)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
