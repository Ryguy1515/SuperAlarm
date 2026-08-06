import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Colour helpers

public extension Color {
    /// Creates a colour from a hex integer such as `0xFFD400`.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// Creates a colour from a hex string such as `"FFD400"`.
    init(hexString: String) {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        let value = UInt32(cleaned, radix: 16) ?? 0xFFD400
        self.init(hex: value)
    }

    /// Resolves differently in light and dark appearance.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
        #else
        self.init(hex: dark)
        #endif
    }
}

// MARK: - Palette

/// The app's visual identity: black, safety yellow and warm cream, with a
/// heavy geometric rounded typeface. Dark is the primary appearance; light
/// mode swaps black for cream and keeps the same yellow.
public enum SAColor {
    /// The signature accent. Identical in both appearances.
    public static let accent = Color(hex: 0xFFD400)
    public static let accentDim = Color(hex: 0xE0BB00)
    public static let onAccent = Color(hex: 0x0A0A0A)

    public static let background = Color(light: 0xF6F1E4, dark: 0x000000)
    /// Cards and grouped rows.
    public static let surface = Color(light: 0xFFFFFF, dark: 0x141414)
    /// Controls sitting on top of a surface.
    public static let surfaceElevated = Color(light: 0xF1EADA, dark: 0x1F1F1F)
    public static let surfaceInverted = Color(light: 0x121212, dark: 0xF6F1E4)

    public static let textPrimary = Color(light: 0x101010, dark: 0xFFFFFF)
    public static let textSecondary = Color(light: 0x6B6659, dark: 0x9A9A9E)
    public static let textTertiary = Color(light: 0x9C9686, dark: 0x636366)
    public static let textOnInverted = Color(light: 0xF6F1E4, dark: 0x101010)

    public static let separator = Color(light: 0xE3DCCB, dark: 0x2A2A2C)

    public static let success = Color(hex: 0x32D74B)
    public static let warning = Color(hex: 0xFF9F0A)
    public static let danger = Color(hex: 0xFF453A)

    /// Cream, used for callout cards on black backgrounds.
    public static let cream = Color(hex: 0xF6F1E4)
    public static let ink = Color(hex: 0x0A0A0A)
}

// MARK: - Typography

/// SF Pro Rounded at heavy weights stands in for the geometric display face,
/// with no font files to bundle and full Dynamic Type support.
public enum SAFont {
    public static func display(_ size: CGFloat = 40) -> Font {
        .system(size: size, weight: .black, design: .rounded)
    }

    public static func title(_ size: CGFloat = 26) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }

    public static func headline(_ size: CGFloat = 19) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    public static func body(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .medium, design: .rounded)
    }

    public static func emphasis(_ size: CGFloat = 16) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    public static func caption(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    /// Monospaced digits so the clock does not jitter as numbers change.
    public static func clock(_ size: CGFloat = 64) -> Font {
        .system(size: size, weight: .black, design: .rounded).monospacedDigit()
    }
}

// MARK: - Metrics

public enum SAMetrics {
    public static let cardRadius: CGFloat = 22
    public static let tileRadius: CGFloat = 20
    public static let buttonRadius: CGFloat = 30
    public static let buttonHeight: CGFloat = 58
    public static let screenPadding: CGFloat = 20
    public static let rowSpacing: CGFloat = 12
}

// MARK: - Buttons

/// The full-width yellow pill used for every primary action.
public struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = SAColor.accent
    var foreground: Color = SAColor.onAccent
    var height: CGFloat = SAMetrics.buttonHeight

    public init(tint: Color = SAColor.accent, foreground: Color = SAColor.onAccent, height: CGFloat = SAMetrics.buttonHeight) {
        self.tint = tint
        self.foreground = foreground
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SAFont.headline(18))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(tint, in: RoundedRectangle(cornerRadius: SAMetrics.buttonRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Muted pill for secondary actions.
public struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = SAMetrics.buttonHeight

    public init(height: CGFloat = SAMetrics.buttonHeight) {
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SAFont.headline(17))
            .foregroundStyle(SAColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(SAColor.surfaceElevated, in: RoundedRectangle(cornerRadius: SAMetrics.buttonRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Small pill used for inline actions such as "Preview".
public struct PillButtonStyle: ButtonStyle {
    var filled: Bool = false

    public init(filled: Bool = false) {
        self.filled = filled
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SAFont.caption(14))
            .foregroundStyle(filled ? SAColor.onAccent : SAColor.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background {
                Capsule()
                    .fill(filled ? SAColor.accent : Color.clear)
                    .overlay(Capsule().strokeBorder(SAColor.accent, lineWidth: filled ? 0 : 1.5))
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Containers

/// Standard rounded card.
public struct SACard<Content: View>: View {
    var background: Color
    var padding: CGFloat
    @ViewBuilder var content: Content

    public init(
        background: Color = SAColor.surface,
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) {
        self.background = background
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: SAMetrics.cardRadius, style: .continuous))
    }
}

/// Section heading used above grouped content.
public struct SASectionHeader: View {
    let title: String
    var subtitle: String?

    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(SAFont.caption(12))
                .kerning(1.1)
                .foregroundStyle(SAColor.textTertiary)
            if let subtitle {
                Text(subtitle)
                    .font(SAFont.body(14))
                    .foregroundStyle(SAColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tappable settings row: icon, title, trailing value, chevron.
public struct SARow<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    var iconTint: Color
    var showsChevron: Bool
    @ViewBuilder var trailing: Trailing

    public init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        iconTint: Color = SAColor.accent,
        showsChevron: Bool = true,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.iconTint = iconTint
        self.showsChevron = showsChevron
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconTint.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SAFont.emphasis(16))
                    .foregroundStyle(SAColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(SAFont.body(13))
                        .foregroundStyle(SAColor.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            trailing
                .font(SAFont.body(15))
                .foregroundStyle(SAColor.textSecondary)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SAColor.textTertiary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

// MARK: - Chips

/// Horizontal category selector, as used by the sound picker.
public struct SAChip: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool

    public init(title: String, systemImage: String? = nil, isSelected: Bool) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .bold))
            }
            Text(title)
                .font(SAFont.caption(14))
        }
        .foregroundStyle(isSelected ? SAColor.onAccent : SAColor.textSecondary)
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .background {
            Capsule().fill(isSelected ? SAColor.accent : SAColor.surfaceElevated)
        }
    }
}

// MARK: - Progress ring

/// Circular countdown used by the wake-up check.
public struct SAProgressRing: View {
    /// 0...1 — how much of the ring remains.
    let progress: Double
    var lineWidth: CGFloat = 10
    var tint: Color = SAColor.accent
    var track: Color = SAColor.separator

    public init(progress: Double, lineWidth: CGFloat = 10, tint: Color = SAColor.accent, track: Color = SAColor.separator) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.tint = tint
        self.track = track
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
        }
    }
}

// MARK: - Stepper

/// Big centred number flanked by circular − and + buttons, matching the
/// step-goal screen.
public struct SABigStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    var caption: String?

    public init(value: Binding<Int>, range: ClosedRange<Int>, step: Int, caption: String? = nil) {
        self._value = value
        self.range = range
        self.step = step
        self.caption = caption
    }

    public var body: some View {
        VStack(spacing: 10) {
            if let caption {
                Text(caption)
                    .font(SAFont.body(15))
                    .foregroundStyle(SAColor.textSecondary)
            }

            HStack(spacing: 28) {
                stepButton(symbol: "minus", enabled: value > range.lowerBound) {
                    value = max(range.lowerBound, value - step)
                }

                Text("\(value)")
                    .font(SAFont.display(52))
                    .foregroundStyle(SAColor.textPrimary)
                    .frame(minWidth: 130)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: value)

                stepButton(symbol: "plus", enabled: value < range.upperBound) {
                    value = min(range.upperBound, value + step)
                }
            }
        }
    }

    private func stepButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            HapticEngine.shared.selection()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(enabled ? SAColor.textPrimary : SAColor.textTertiary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(SAColor.surfaceElevated))
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }
}

// MARK: - Difficulty pips

public struct SADifficultyPips: View {
    let level: Int

    public init(level: Int) {
        self.level = level
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { index in
                Capsule()
                    .fill(index <= level ? SAColor.accent : SAColor.separator)
                    .frame(width: 12, height: 4)
            }
        }
    }
}

// MARK: - Background

/// Standard screen background.
public struct SABackground: View {
    public init() {}

    public var body: some View {
        SAColor.background.ignoresSafeArea()
    }
}

// MARK: - Conveniences

public extension View {
    /// Applies the app's screen chrome: background plus horizontal padding.
    func saScreen() -> some View {
        self
            .background(SABackground())
            .tint(SAColor.accent)
    }

    /// Groups rows into a single rounded card with separators between them.
    func saGroupedCard() -> some View {
        self.background(SAColor.surface, in: RoundedRectangle(cornerRadius: SAMetrics.cardRadius, style: .continuous))
    }
}

/// Thin divider matched to the palette.
public struct SADivider: View {
    var inset: CGFloat = 16

    public init(inset: CGFloat = 16) {
        self.inset = inset
    }

    public var body: some View {
        Rectangle()
            .fill(SAColor.separator)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}
