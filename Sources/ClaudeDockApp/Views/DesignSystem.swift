// FILE: Views/DesignSystem.swift
import AppKit
import ClaudeDockCore
import SwiftUI

/// ClaudeDock's design system: 4/8-pt spatial rhythm, adaptive light/dark surfaces, custom tactile controls,
/// and accessible motion tokens.
enum DS {
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 40
        /// Standard page horizontal inset (4pt multiple).
        static let page: CGFloat = 28
        /// Clearance for the unified transparent titlebar / traffic-light row.
        static let titlebarHeight: CGFloat = 52
    }

    enum Radius {
        static let xs: CGFloat = 4      // key caps, micro badges
        static let s: CGFloat = 6       // compact inner tags
        static let button: CGFloat = 8  // buttons, sidebar rows, icon controls
        static let m: CGFloat = 10      // nested card wells, sub-panels
        static let l: CGFloat = 14      // cards, metric tiles, incident banners, toasts
        static let xl: CGFloat = 18     // hero containers, empty states
    }

    /// Cohesive integer-point type scale tuned for macOS Retina + Simplified Chinese legibility.
    enum Typo {
        static let largeTitle = Font.system(size: 26, weight: .semibold)
        static let pageTitle = Font.system(size: 22, weight: .semibold)
        static let title = Font.system(size: 17, weight: .semibold)
        static let cardTitle = Font.system(size: 15, weight: .semibold)
        static let headline = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let pageSubtitle = Font.system(size: 13, weight: .regular)
        static let sectionTitle = Font.system(size: 13, weight: .semibold)
        static let secondary = Font.system(size: 12, weight: .regular)
        static let caption = Font.system(size: 11, weight: .regular)
        static let micro = Font.system(size: 10, weight: .medium)
        static let metric = Font.system(size: 22, weight: .semibold, design: .rounded)
        static let figure = Font.system(size: 15, weight: .semibold, design: .rounded)
    }

    // MARK: Adaptive Semantic Colors

    /// Main detail canvas: cool alabaster in light mode so white cards float; deep obsidian in dark mode.
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.075, green: 0.078, blue: 0.090, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1)
    })

    /// Elevated card surface: crisp white in light mode; lifted slate above the dark canvas in dark mode.
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.116, green: 0.122, blue: 0.141, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    })

    /// Hovered interactive card surface.
    static let cardHoverFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.135, green: 0.142, blue: 0.165, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    })

    /// Recessed sub-panel inside a card (quota well, egress readout).
    static let subtleFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.038)
            : NSColor(srgbRed: 0.06, green: 0.08, blue: 0.14, alpha: 0.032)
    })

    /// Secondary button resting fill.
    static let controlFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.075)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    })

    /// Secondary button hover fill.
    static let controlHoverFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.115)
            : NSColor(srgbRed: 0.953, green: 0.958, blue: 0.969, alpha: 1)
    })

    /// Secondary button pressed fill.
    static let controlPressedFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.055)
            : NSColor(srgbRed: 0.922, green: 0.929, blue: 0.945, alpha: 1)
    })

    /// Resting 1px border token.
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.085)
            : NSColor(white: 0.0, alpha: 0.075)
    })

    /// Hovered / emphasized 1px border token.
    static let hairlineStrong = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.16)
            : NSColor(white: 0.0, alpha: 0.135)
    })

    /// Specular top-edge highlight inside cards and controls.
    static let innerHighlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.065)
            : NSColor(white: 1.0, alpha: 0.90)
    })

    enum Semantic {
        static let verified = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.20, green: 0.83, blue: 0.48, alpha: 1)
                : NSColor(srgbRed: 0.04, green: 0.48, blue: 0.28, alpha: 1)
        })

        static let caution = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 1.0, green: 0.64, blue: 0.14, alpha: 1)
                : NSColor(srgbRed: 0.64, green: 0.33, blue: 0.02, alpha: 1)
        })

        static let critical = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 1.0, green: 0.32, blue: 0.28, alpha: 1)
                : NSColor(srgbRed: 0.85, green: 0.18, blue: 0.18, alpha: 1)
        })

        static let brand = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.90, green: 0.50, blue: 0.36, alpha: 1)
                : NSColor(srgbRed: 0.82, green: 0.41, blue: 0.27, alpha: 1)
        })
    }

    // MARK: Contrast-Adaptive Color Helpers

    /// Returns an appearance-adaptive foreground color that meets WCAG AA (≥ 4.5:1)
    /// over both light and dark card / subtle-tinted button surfaces.
    static func legibleForeground(_ base: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            guard let rgb = resolved.usingColorSpace(.sRGB), rgb.alphaComponent >= 0.95 else {
                return resolved
            }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let r = rgb.redComponent
            let g = rgb.greenComponent
            let b = rgb.blueComponent
            let a = rgb.alphaComponent
            let lum = relativeLuminance(r: r, g: g, b: b)

            if isDark {
                let target: CGFloat = 0.35
                guard lum < target else { return rgb }
                return liftLuminance(r: r, g: g, b: b, a: a, target: target)
            } else {
                let target: CGFloat = 0.14
                guard lum > target else { return rgb }
                return lowerLuminance(r: r, g: g, b: b, a: a, target: target)
            }
        })
    }

    static func legibleForeground(_ color: Color) -> Color {
        legibleForeground(NSColor(color))
    }

    /// Deepens overly bright fills so `.white` button/monogram labels achieve ≥ 4.5:1 contrast.
    static func legibleFillForWhiteText(_ base: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            guard let rgb = resolved.usingColorSpace(.sRGB), rgb.alphaComponent >= 0.95 else {
                return resolved
            }
            let r = rgb.redComponent
            let g = rgb.greenComponent
            let b = rgb.blueComponent
            let a = rgb.alphaComponent
            let target: CGFloat = 0.165
            guard relativeLuminance(r: r, g: g, b: b) > target else { return rgb }
            return lowerLuminance(r: r, g: g, b: b, a: a, target: target)
        })
    }

    static func legibleFillForWhiteText(_ color: Color) -> Color {
        legibleFillForWhiteText(NSColor(color))
    }

    private static func linearize(_ c: CGFloat) -> CGFloat {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func relativeLuminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    private static func liftLuminance(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat, target: CGFloat) -> NSColor {
        let maxC = max(r, max(g, b))
        if maxC > 0.001 {
            let maxScale = 1.0 / maxC
            let brightR = min(1, r * maxScale)
            let brightG = min(1, g * maxScale)
            let brightB = min(1, b * maxScale)
            if relativeLuminance(r: brightR, g: brightG, b: brightB) >= target {
                var lo: CGFloat = 1.0
                var hi: CGFloat = maxScale
                for _ in 0..<14 {
                    let mid = (lo + hi) * 0.5
                    if relativeLuminance(r: r * mid, g: g * mid, b: b * mid) < target {
                        lo = mid
                    } else {
                        hi = mid
                    }
                }
                return NSColor(srgbRed: min(1, r * hi), green: min(1, g * hi), blue: min(1, b * hi), alpha: a)
            }
            var lo: CGFloat = 0.0
            var hi: CGFloat = 1.0
            for _ in 0..<14 {
                let mid = (lo + hi) * 0.5
                let nr = brightR + (1 - brightR) * mid
                let ng = brightG + (1 - brightG) * mid
                let nb = brightB + (1 - brightB) * mid
                if relativeLuminance(r: nr, g: ng, b: nb) < target {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            return NSColor(
                srgbRed: brightR + (1 - brightR) * hi,
                green: brightG + (1 - brightG) * hi,
                blue: brightB + (1 - brightB) * hi,
                alpha: a
            )
        } else {
            var lo: CGFloat = 0.0
            var hi: CGFloat = 1.0
            for _ in 0..<14 {
                let mid = (lo + hi) * 0.5
                if relativeLuminance(r: mid, g: mid, b: mid) < target {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            return NSColor(srgbRed: hi, green: hi, blue: hi, alpha: a)
        }
    }

    private static func lowerLuminance(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat, target: CGFloat) -> NSColor {
        var lo: CGFloat = 0.0
        var hi: CGFloat = 1.0
        for _ in 0..<14 {
            let mid = (lo + hi) * 0.5
            if relativeLuminance(r: r * mid, g: g * mid, b: b * mid) > target {
                hi = mid
            } else {
                lo = mid
            }
        }
        return NSColor(srgbRed: r * lo, green: g * lo, blue: b * lo, alpha: a)
    }

    enum Motion {
        static let quick = Animation.snappy(duration: 0.16)
        static let standard = Animation.snappy(duration: 0.24)
        static let spring = Animation.spring(response: 0.34, dampingFraction: 0.84)
        static let gentle = Animation.easeOut(duration: 0.42)

        /// True when the user asked macOS to reduce motion.
        @MainActor static var reduceMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }
}

// MARK: - Translucent Sidebar Backdrop

/// Native AppKit behind-window vibrancy that extends seamlessly under a transparent unified titlebar.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
    }
}

// MARK: - Layered Card Surface

/// Layered card surface: adaptive fill, optional status tint, 1px specular top highlight, 1px hairline border,
/// soft two-step shadow, and gentle hover lift.
struct SurfaceModifier: ViewModifier {
    var accent: Color?
    var tint: Color?
    var isHovered: Bool = false

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pixel: CGFloat { 1 / max(1, displayScale) }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
        let isDark = colorScheme == .dark

        content
            .background {
                ZStack {
                    shape.fill(isHovered ? DS.cardHoverFill : DS.cardFill)
                    if let tint {
                        shape.fill(
                            LinearGradient(
                                colors: [tint.opacity(isDark ? 0.11 : 0.08), tint.opacity(isDark ? 0.04 : 0.025)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [DS.innerHighlight, .clear],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: pixel
                        )
                        .padding(pixel)
                }
            }
            .overlay {
                shape.strokeBorder(
                    accent.map { $0.opacity(isHovered ? 0.68 : 0.48) } ?? (isHovered ? DS.hairlineStrong : DS.hairline),
                    lineWidth: accent == nil ? pixel : max(1.25, pixel * 1.5)
                )
            }
            // Step 1: crisp contact shadow
            .shadow(
                color: .black.opacity(isDark ? 0.24 : (isHovered ? 0.055 : 0.03)),
                radius: isHovered ? 2.5 : 1.5,
                y: 1
            )
            // Step 2: soft ambient elevation shadow
            .shadow(
                color: .black.opacity(isDark ? (isHovered ? 0.34 : 0.16) : (isHovered ? 0.085 : 0.04)),
                radius: isHovered ? 16 : 8,
                y: isHovered ? 6 : 3
            )
            .offset(y: isHovered && !reduceMotion ? -1.5 : 0)
    }
}

extension View {
    func surface(accent: Color? = nil, tint: Color? = nil, hovered: Bool = false) -> some View {
        modifier(SurfaceModifier(accent: accent, tint: tint, isHovered: hovered))
    }
}

/// Composable Card container built on the layered surface.
struct Card<Content: View>: View {
    var padding: CGFloat = DS.Space.l
    var accent: Color?
    var tint: Color?
    var isHovered: Bool = false
    @ViewBuilder var content: () -> Content

    init(
        padding: CGFloat = DS.Space.l,
        accent: Color? = nil,
        tint: Color? = nil,
        hovered: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.accent = accent
        self.tint = tint
        self.isHovered = hovered
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .surface(accent: accent, tint: tint, hovered: isHovered)
    }
}

// MARK: - Custom Button Kit

private enum ButtonMetrics {
    static func font(for size: ControlSize) -> Font {
        switch size {
        case .mini: return .system(size: 11, weight: .semibold)
        case .small: return .system(size: 12, weight: .semibold)
        case .large, .extraLarge: return .system(size: 14, weight: .semibold)
        case .regular: return .system(size: 13, weight: .semibold)
        @unknown default: return .system(size: 13, weight: .semibold)
        }
    }

    static func horizontalPadding(for size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 8
        case .small: return 10
        case .large, .extraLarge: return 18
        case .regular: return 14
        @unknown default: return 14
        }
    }

    static func verticalPadding(for size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 4
        case .small: return 5
        case .large, .extraLarge: return 9
        case .regular: return 6
        @unknown default: return 6
        }
    }

    static func minHeight(for size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 22
        case .small: return 26
        case .large, .extraLarge: return 36
        case .regular: return 30
        @unknown default: return 30
        }
    }
}

/// Primary CTA button style: 8pt continuous radius, subtle vertical sheen, 1px inner top highlight,
/// hover/pressed tactile states, keyboard focus ring, and account-tinted variant.
struct PrimaryButton: ButtonStyle {
    var tint: Color = .accentColor
    var fullWidth: Bool = false

    init(tint: Color = .accentColor, fullWidth: Bool = false) {
        self.tint = tint
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonContent(configuration: configuration, tint: tint, fullWidth: fullWidth)
    }

    private struct PrimaryButtonContent: View {
        let configuration: Configuration
        let tint: Color
        let fullWidth: Bool

        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.controlSize) private var controlSize
        @Environment(\.displayScale) private var displayScale
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var pixel: CGFloat { 1 / max(1, displayScale) }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
            let pressed = configuration.isPressed
            let fillTint = DS.legibleFillForWhiteText(tint)

            configuration.label
                .font(ButtonMetrics.font(for: controlSize))
                .foregroundStyle(.white)
                .padding(.horizontal, ButtonMetrics.horizontalPadding(for: controlSize))
                .padding(.vertical, ButtonMetrics.verticalPadding(for: controlSize))
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: ButtonMetrics.minHeight(for: controlSize))
                .background {
                    ZStack {
                        shape.fill(fillTint)
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(pressed ? 0.03 : (isHovered ? 0.16 : 0.10)),
                                    .white.opacity(0.0),
                                    .black.opacity(pressed ? 0.16 : 0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        shape
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(pressed ? 0.14 : 0.34), .white.opacity(0.06)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: pixel
                            )
                            .padding(pixel)
                    }
                }
                .overlay {
                    shape.strokeBorder(.black.opacity(0.14), lineWidth: pixel)
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: DS.Radius.button + 3, style: .continuous)
                            .strokeBorder(fillTint.opacity(0.65), lineWidth: 2)
                            .padding(-3)
                    }
                }
                .shadow(
                    color: fillTint.opacity(isEnabled ? (pressed ? 0.10 : (isHovered ? 0.30 : 0.18)) : 0),
                    radius: pressed ? 2 : (isHovered ? 8 : 4),
                    y: pressed ? 0 : 2
                )
                .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.44)
                .contentShape(shape)
                .onHover { hovering in
                    withAnimation(DS.Motion.quick) { isHovered = hovering }
                }
                .animation(DS.Motion.quick, value: pressed)
        }
    }
}

typealias PrimaryButtonStyle = PrimaryButton

/// Secondary button style: crisp elevated surface (or soft semantic tint), 1px hairline, focus ring, 8pt radius.
struct SecondaryButton: ButtonStyle {
    var tint: Color?
    var fullWidth: Bool = false

    init(tint: Color? = nil, fullWidth: Bool = false) {
        self.tint = tint
        self.fullWidth = fullWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonContent(configuration: configuration, tint: tint, fullWidth: fullWidth)
    }

    private struct SecondaryButtonContent: View {
        let configuration: Configuration
        let tint: Color?
        let fullWidth: Bool

        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.controlSize) private var controlSize
        @Environment(\.displayScale) private var displayScale
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var pixel: CGFloat { 1 / max(1, displayScale) }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
            let pressed = configuration.isPressed
            let legibleTint = tint.map { DS.legibleForeground($0) }

            configuration.label
                .font(ButtonMetrics.font(for: controlSize))
                .foregroundStyle(legibleTint ?? Color.primary)
                .padding(.horizontal, ButtonMetrics.horizontalPadding(for: controlSize))
                .padding(.vertical, ButtonMetrics.verticalPadding(for: controlSize))
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: ButtonMetrics.minHeight(for: controlSize))
                .background {
                    if let tint {
                        shape.fill(tint.opacity(pressed ? 0.17 : (isHovered ? 0.12 : 0.08)))
                    } else {
                        ZStack {
                            shape.fill(pressed ? DS.controlPressedFill : (isHovered ? DS.controlHoverFill : DS.controlFill))
                            shape
                                .strokeBorder(
                                    LinearGradient(colors: [DS.innerHighlight, .clear], startPoint: .top, endPoint: .bottom),
                                    lineWidth: pixel
                                )
                                .padding(pixel)
                        }
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        legibleTint.map { $0.opacity(isHovered ? 0.44 : 0.28) } ?? (isHovered ? DS.hairlineStrong : DS.hairline),
                        lineWidth: pixel
                    )
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: DS.Radius.button + 3, style: .continuous)
                            .strokeBorder((legibleTint ?? Color.accentColor).opacity(0.65), lineWidth: 2)
                            .padding(-3)
                    }
                }
                .shadow(
                    color: .black.opacity(tint == nil && isEnabled && !pressed ? 0.035 : 0),
                    radius: 2,
                    y: 1
                )
                .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
                .opacity(isEnabled ? 1 : 0.42)
                .contentShape(shape)
                .onHover { hovering in
                    withAnimation(DS.Motion.quick) { isHovered = hovering }
                }
                .animation(DS.Motion.quick, value: pressed)
        }
    }
}

typealias SecondaryButtonStyle = SecondaryButton

/// Ghost icon button style: borderless at rest, crisp 8pt pill on hover/press, keyboard focus ring.
struct GhostIconButton: ButtonStyle {
    var size: CGFloat = 28
    var tint: Color?

    init(size: CGFloat = 28, tint: Color? = nil) {
        self.size = size
        self.tint = tint
    }

    func makeBody(configuration: Configuration) -> some View {
        GhostIconButtonContent(configuration: configuration, size: size, tint: tint)
    }

    private struct GhostIconButtonContent: View {
        let configuration: Configuration
        let size: CGFloat
        let tint: Color?

        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.displayScale) private var displayScale
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var pixel: CGFloat { 1 / max(1, displayScale) }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
            let pressed = configuration.isPressed
            let foreground = tint.map { DS.legibleForeground($0) } ?? (isHovered ? Color.primary : Color.secondary)

            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background {
                    shape.fill(Color.primary.opacity(pressed ? 0.11 : (isHovered ? 0.065 : 0)))
                }
                .overlay {
                    if isHovered || pressed {
                        shape.strokeBorder(DS.hairline, lineWidth: pixel)
                    }
                }
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: DS.Radius.button + 2, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 2)
                            .padding(-2)
                    }
                }
                .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(shape)
                .onHover { hovering in
                    withAnimation(DS.Motion.quick) { isHovered = hovering }
                }
                .animation(DS.Motion.quick, value: pressed)
        }
    }
}

typealias GhostIconButtonStyle = GhostIconButton

extension ButtonStyle where Self == PrimaryButton {
    static var dsPrimary: PrimaryButton { PrimaryButton() }
    static func dsPrimary(tint: Color, fullWidth: Bool = false) -> PrimaryButton {
        PrimaryButton(tint: tint, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == SecondaryButton {
    static var dsSecondary: SecondaryButton { SecondaryButton() }
    static func dsSecondary(tint: Color? = nil, fullWidth: Bool = false) -> SecondaryButton {
        SecondaryButton(tint: tint, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == GhostIconButton {
    static var dsGhostIcon: GhostIconButton { GhostIconButton() }
    static func dsGhostIcon(size: CGFloat = 28, tint: Color? = nil) -> GhostIconButton {
        GhostIconButton(size: size, tint: tint)
    }
}

/// Custom-styled icon menu button matching `GhostIconButton` without stock macOS bezel chrome.
struct GhostMenuButton<MenuItems: View>: View {
    var symbol: String = "ellipsis"
    var size: CGFloat = 28
    var label: String = String(localized: "更多操作")
    @ViewBuilder var items: () -> MenuItems

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.displayScale) private var displayScale

    init(
        symbol: String = "ellipsis",
        size: CGFloat = 28,
        label: String = String(localized: "更多操作"),
        @ViewBuilder items: @escaping () -> MenuItems
    ) {
        self.symbol = symbol
        self.size = size
        self.label = label
        self.items = items
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
        Menu {
            items()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: size, height: size)
                .contentShape(shape)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: size, height: size)
        .background(shape.fill(Color.primary.opacity(isHovered && isEnabled ? 0.065 : 0)))
        .overlay {
            if isHovered && isEnabled {
                shape.strokeBorder(DS.hairline, lineWidth: 1 / max(1, displayScale))
            }
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: DS.Radius.button + 2, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 2)
                    .padding(-2)
            }
        }
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .onHover { hovering in
            withAnimation(DS.Motion.quick) { isHovered = hovering }
        }
    }
}

// MARK: - Custom Sidebar Kit

/// Capsule counter/status badge inside custom sidebar rows.
struct SidebarBadge: View {
    let text: String
    var tone: Color = .secondary
    var emphasized: Bool = false

    init(_ text: String, tone: Color = .secondary, emphasized: Bool = false) {
        self.text = text
        self.tone = tone
        self.emphasized = emphasized
    }

    var body: some View {
        let foregroundTone = DS.legibleForeground(tone)
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(emphasized ? foregroundTone : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(emphasized ? tone.opacity(0.14) : Color.primary.opacity(0.07))
            )
    }
}

/// Rounded selection pill with tinted fill, hover highlight, and optional trailing badge.
struct SidebarRowChrome: ViewModifier {
    let isSelected: Bool
    var accent: Color = .accentColor

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous)
        let isDark = colorScheme == .dark

        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    shape.fill(accent.opacity(isDark ? 0.20 : 0.13))
                } else if isHovered {
                    shape.fill(Color.primary.opacity(isDark ? 0.065 : 0.045))
                }
            }
            .overlay {
                if isSelected {
                    shape.strokeBorder(
                        accent.opacity(isDark ? 0.32 : 0.22),
                        lineWidth: 1 / max(1, displayScale)
                    )
                }
            }
            .contentShape(shape)
            .onHover { hovering in
                withAnimation(DS.Motion.quick) { isHovered = hovering }
            }
    }
}

extension View {
    func sidebarRowStyle(selected: Bool, accent: Color = .accentColor) -> some View {
        modifier(SidebarRowChrome(isSelected: selected, accent: accent))
    }
}

// MARK: - Page Scaffolding

/// Large page title with optional one-line summary and trailing actions.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Typo.pageTitle)
                    .tracking(-0.2)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(DS.Typo.pageSubtitle)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: DS.Space.m)
            trailing()
        }
    }
}

/// Section header with optional count pill, detail caption, and trailing controls.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    var count: Int?
    @ViewBuilder var trailing: () -> Trailing

    init(
        _ title: String,
        detail: String? = nil,
        count: Int? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.detail = detail
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            Text(title)
                .font(DS.Typo.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            if let count {
                SidebarBadge("\(count)")
            }
            if let detail {
                Text(detail)
                    .font(DS.Typo.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
            trailing()
        }
    }
}

/// Backward-compatible section heading inside a page.
struct SectionLabel: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        SectionHeader(title, detail: detail)
    }
}

/// Scrolling page body with generous spatial insets and comfortable bottom clearance.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                content()
            }
            .padding(.horizontal, DS.Space.page)
            .padding(.top, DS.Space.m)
            .padding(.bottom, DS.Space.xxl)
            .frame(maxWidth: 1140, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Identity, StatusDot, Pills & KeyCaps

extension AccountProfile {
    var accentColor: Color {
        if let ns = IconRenderer.nsColor(fromHex: colorHex) {
            return DS.legibleForeground(ns)
        }
        return .accentColor
    }

    /// First character of the name, uppercased (works for CJK names too).
    var monogram: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }
}

extension RunningState {
    var dotColor: Color {
        switch self {
        case .running: return DS.Semantic.verified
        case .frozen: return DS.Semantic.caution
        case .stopped: return Color.secondary.opacity(0.45)
        }
    }

    var label: String {
        switch self {
        case .running: return String(localized: "运行中")
        case .frozen: return String(localized: "已暂停")
        case .stopped: return String(localized: "未运行")
        }
    }
}

/// Live status dot with a gentle breathing halo while running (degrades gracefully under Reduce Motion).
struct StatusDot: View {
    private struct PulseKey: Equatable {
        let isPulsing: Bool
        let reduceMotion: Bool
    }

    let color: Color
    var isPulsing: Bool = false
    var size: CGFloat = 8

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: RunningState, size: CGFloat = 8) {
        self.color = state.dotColor
        if case .running = state {
            self.isPulsing = true
        } else {
            self.isPulsing = false
        }
        self.size = size
    }

    init(color: Color, isPulsing: Bool = false, size: CGFloat = 8) {
        self.color = color
        self.isPulsing = isPulsing
        self.size = size
    }

    var body: some View {
        ZStack {
            if isPulsing {
                Circle()
                    .fill(color.opacity(reduceMotion ? 0.22 : (expanded ? 0.0 : 0.36)))
                    .frame(width: size * 2.1, height: size * 2.1)
                    .scaleEffect(reduceMotion ? 0.85 : (expanded ? 1.15 : 0.55))
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size + 6, height: size + 6)
        .task(id: PulseKey(isPulsing: isPulsing, reduceMotion: reduceMotion)) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                expanded = false
            }
            guard isPulsing, !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 1.9).repeatForever(autoreverses: false)) {
                expanded = true
            }
        }
        .onDisappear {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) {
                expanded = false
            }
        }
        .accessibilityHidden(true)
    }
}

/// Rounded monogram tile in the account's color with a punched-out status indicator.
struct AccountAvatar: View {
    enum Size: CGFloat { case small = 20, row = 28, card = 38, large = 44 }

    let account: AccountProfile
    var state: RunningState = .stopped
    var size: CGFloat = Size.card.rawValue
    var isDecorative: Bool = true

    @Environment(\.displayScale) private var displayScale

    init(
        account: AccountProfile,
        state: RunningState = .stopped,
        size: CGFloat = Size.card.rawValue,
        isDecorative: Bool = true
    ) {
        self.account = account
        self.state = state
        self.size = size
        self.isDecorative = isDecorative
    }

    private var dot: CGFloat { max(6, (size * 0.29).rounded()) }
    private var gap: CGFloat { size >= 28 ? 2 : 1.5 }

    private var tileColor: Color {
        if let ns = IconRenderer.nsColor(fromHex: account.colorHex) {
            return DS.legibleFillForWhiteText(ns)
        }
        return DS.legibleFillForWhiteText(.accentColor)
    }

    var body: some View {
        let radius = (size * 0.28).rounded()
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tileColor.opacity(0.92), tileColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.20), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
                .overlay(
                    Text(account.monogram)
                        .font(.system(size: (size * 0.44).rounded(), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.24), lineWidth: 1 / max(1, displayScale))
                )
                .mask {
                    ZStack(alignment: .bottomTrailing) {
                        Rectangle()
                        Circle()
                            .frame(width: dot + gap * 2, height: dot + gap * 2)
                            .offset(x: size * 0.08 + gap, y: size * 0.08 + gap)
                            .blendMode(.destinationOut)
                    }
                    .compositingGroup()
                }
                .frame(width: size, height: size)

            Circle()
                .fill(state.dotColor)
                .frame(width: dot, height: dot)
                .offset(x: size * 0.08, y: size * 0.08)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isDecorative ? "" : String(localized: "\(account.name)，\(state.label)"))
        .accessibilityHidden(isDecorative)
    }
}

/// Sculpted physical keyboard keycap badge.
struct KeyCap: View {
    let text: String
    @Environment(\.displayScale) private var displayScale

    init(text: String) {
        self.text = text
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(shape.fill(DS.controlFill))
            .overlay(shape.strokeBorder(DS.hairlineStrong, lineWidth: 1 / max(1, displayScale)))
            .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
            .accessibilityLabel("快捷键 \(text)")
    }
}

/// Semantic capsule pill with optional leading SF Symbol and hairline border.
struct Pill: View {
    let text: String
    var symbol: String?
    var color: Color = .secondary

    @Environment(\.displayScale) private var displayScale

    init(text: String, symbol: String? = nil, color: Color = .secondary) {
        self.text = text
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        let foreground = DS.legibleForeground(color)

        HStack(spacing: 3.5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(0.10), in: Capsule())
        .overlay(
            Capsule().strokeBorder(foreground.opacity(0.24), lineWidth: 1 / max(1, displayScale))
        )
        .fixedSize()
    }
}

/// Compact capsule tag (backward-compatible wrapper over the Pill visual language).
struct Tag: View {
    let text: String
    var color: Color = .secondary
    var symbol: String?

    init(text: String, color: Color = .secondary, symbol: String? = nil) {
        self.text = text
        self.color = color
        self.symbol = symbol
    }

    var body: some View {
        Pill(text: text, symbol: symbol, color: color)
    }
}

// MARK: - Redesigned Metric Tile & Empty State

/// Summary metric card: tinted icon medallion, crisp headline figure, contextual subtitle, and optional action.
struct MetricTile<Accessory: View>: View {
    let title: String
    let value: String
    var detail: String?
    let symbol: String
    var tone: Color = .accentColor
    var isNumeric: Bool = false
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.displayScale) private var displayScale

    init(
        title: String,
        value: String,
        detail: String? = nil,
        symbol: String,
        tone: Color = .accentColor,
        isNumeric: Bool = false,
        @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
        self.tone = tone
        self.isNumeric = isNumeric
        self.accessory = accessory
    }

    var body: some View {
        let legibleTone = DS.legibleForeground(tone)

        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tone.opacity(0.12))
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(legibleTone.opacity(0.24), lineWidth: 1 / max(1, displayScale))
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(legibleTone)
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: DS.Space.xs)

                accessory()
                    .controlSize(.small)
            }
            .frame(minHeight: 26)

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(value)
                    .font(DS.Typo.metric)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.8)
                    .monospacedDigit()
                    .contentTransition(isNumeric ? .numericText() : .identity)
                    .help(value)

                if let detail {
                    Text(detail)
                        .font(DS.Typo.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(detail)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface()
        .accessibilityElement(children: Accessory.self == EmptyView.self ? .combine : .contain)
    }
}

/// Cohesive empty-state block with layered medallion, clear headline, supporting copy, and primary CTA slot.
struct EmptyStateView<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = DS.Semantic.brand
    @ViewBuilder var actions: () -> Actions

    @Environment(\.displayScale) private var displayScale

    init(
        symbol: String,
        title: String,
        message: String,
        tint: Color = DS.Semantic.brand,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.tint = tint
        self.actions = actions
    }

    var body: some View {
        let medallionFill = DS.legibleFillForWhiteText(tint)

        VStack(spacing: DS.Space.l) {
            ZStack {
                Circle()
                    .fill(medallionFill.opacity(0.09))
                    .frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [medallionFill.opacity(0.92), medallionFill],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(0.28), lineWidth: 1 / max(1, displayScale))
                    )
                    .shadow(color: medallionFill.opacity(0.28), radius: 12, y: 5)
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(DS.Typo.title)
                Text(message)
                    .font(DS.Typo.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            actions()
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Removes the window's toolbar title where supported (pages show their own large title).
    @ViewBuilder
    func hidingToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbar(removing: .title)
        } else {
            self
        }
    }

    /// Hides the opaque window toolbar background so content extends seamlessly under the unified titlebar.
    @ViewBuilder
    func seamlessWindowToolbar() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self.toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

/// Form section footer, aligned with the section's content instead of the trailing edge.
struct FooterText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Typo.secondary)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Motion Modifiers

private struct AppearModifier: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true; return }
                withAnimation(DS.Motion.spring.delay(min(Double(index), 8) * 0.032)) { shown = true }
            }
    }
}

private struct PulseModifier: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Read the environment value once on the main actor; the animator's content closure is Sendable.
        let still = reduceMotion
        return content.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { view, scale in
            view.scaleEffect(still ? 1 : scale)
        } keyframes: { _ in
            CubicKeyframe(0.978, duration: 0.09)
            SpringKeyframe(1.0, duration: 0.28, spring: .snappy)
        }
    }
}

extension View {
    func appearAnimation(index: Int = 0) -> some View { modifier(AppearModifier(index: index)) }
    func pulse(on trigger: Int) -> some View { modifier(PulseModifier(trigger: trigger)) }
}

// MARK: - Hairlines & Palette Names

private struct HairlineBorder<S: InsettableShape>: ViewModifier {
    let shape: S
    var color: Color
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay(shape.strokeBorder(color, lineWidth: 1 / max(1, displayScale)))
    }
}

extension View {
    /// A border exactly one physical pixel wide on any display.
    func hairlineBorder<S: InsettableShape>(_ shape: S, _ color: Color = DS.hairline) -> some View {
        modifier(HairlineBorder(shape: shape, color: color))
    }
}

/// Human names for the account palette, for VoiceOver and tooltips.
enum PaletteName {
    static func name(_ hex: String) -> String {
        switch hex.uppercased() {
        case "3B6FD8": return String(localized: "蓝色")
        case "2E9D6A": return String(localized: "绿色")
        case "7A5AE0": return String(localized: "紫色")
        case "1F9AA8": return String(localized: "青色")
        case "D2504B": return String(localized: "红色")
        case "C98A12": return String(localized: "琥珀色")
        case "C8508A": return String(localized: "粉色")
        case "5C6470": return String(localized: "石墨色")
        default: return String(localized: "自定义颜色")
        }
    }
}
