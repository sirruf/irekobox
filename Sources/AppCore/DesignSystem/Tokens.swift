import SwiftUI
import AppKit

/// Design tokens: spacing, radii, typography roles and semantic colors.
///
/// Colors are dynamic (light/dark). Status colors come in two strengths: `fill`
/// for dots and bars, and `text` for labels — the text shades keep 4.5:1
/// contrast on the window background, which the system greens and oranges
/// don't as text.
enum DS {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let small: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 14
        /// Raised panels on the window background.
        static let panel: CGFloat = 18
    }

    enum Font {
        /// Values that must line up or stay put while updating: ports, ids, sizes.
        static let mono = SwiftUI.Font.system(.callout, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(.caption, design: .monospaced)
        /// Small caps-style section headers ("REACH IT").
        static let sectionHeader = SwiftUI.Font.caption.weight(.semibold)
    }

    // MARK: - Colors

    static let accent = dynamic(light: 0x0A5DC2, dark: 0x4C9AFF)
    /// Hairline separators and card borders.
    static let separator = Color(nsColor: .separatorColor)
    /// Grouped surfaces (cards, inspector).
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// The window background behind raised panels (Overview).
    static let canvas = dynamic(light: 0xF5F5F7, dark: 0x1C1C1E)
    /// Raised panels on `canvas`.
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let subtleFill = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
    /// Memory and disk next to the accent (CPU) in usage rings.
    static let memory = dynamic(light: 0x6E48C9, dark: 0xA88BFA)
    static let disk = dynamic(light: 0xC2570A, dark: 0xFF9F5A)

    /// Chart series, in this fixed order (never by rank). Checked for colour-blind
    /// separation and contrast on light and dark surfaces.
    static let series: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5),   // blue
        dynamic(light: 0xEB6834, dark: 0xD95926),   // orange
    ]

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
                                                    .accessibilityHighContrastAqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            let color = NSColor(hex: isDark ? dark : light)
            // Increase Contrast: darker on light, brighter on dark.
            switch match {
            case .accessibilityHighContrastAqua?: return color.blended(withFraction: 0.25, of: .black) ?? color
            case .accessibilityHighContrastDarkAqua?: return color.blended(withFraction: 0.2, of: .white) ?? color
            default: return color
            }
        })
    }
}

/// The meaning of a status, independent of what it describes.
enum Tone: Sendable, Equatable {
    case positive    // running, healthy
    case warning     // restarting, degraded
    case critical    // failed, unhealthy
    case info        // informational notices
    case neutral     // stopped by the user, idle
    case inactive    // unknown, not applicable

    /// Dots, bars, outlines.
    var fill: Color {
        switch self {
        case .positive: return DS.dynamic(light: 0x1F9D55, dark: 0x30D158)
        case .warning: return DS.dynamic(light: 0xD97706, dark: 0xFF9F0A)
        case .critical: return DS.dynamic(light: 0xD63031, dark: 0xFF453A)
        case .info: return DS.accent
        case .neutral: return Color(nsColor: .secondaryLabelColor)
        case .inactive: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    /// Labels on the window background (≥ 4.5:1).
    var text: Color {
        switch self {
        case .positive: return DS.dynamic(light: 0x1A7F37, dark: 0x32D74B)
        case .warning: return DS.dynamic(light: 0xB45309, dark: 0xFFB340)
        case .critical: return DS.dynamic(light: 0xA61B1B, dark: 0xFF6961)
        case .info: return DS.accent
        case .neutral, .inactive: return Color(nsColor: .secondaryLabelColor)
        }
    }

    /// Tinted backgrounds for pills and notices.
    var background: Color { fill.opacity(0.13) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
