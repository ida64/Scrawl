import AppKit
import SwiftUI

/// Scrawl's design tokens. Every piece of chrome pulls color, spacing and radius from here so
/// the app reads as one product rather than a collection of default controls.
enum ScrawlTheme {
    // MARK: Spacing

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
    }

    // MARK: Corner radii

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let panel: CGFloat = 10
    }

    // MARK: Layout metrics

    enum Metrics {
        static let railWidth: CGFloat = 46
        static let railButton: CGFloat = 32
        static let statusBarHeight: CGFloat = 26
        static let inspectorWidth: CGFloat = 272
        static let sidebarWidth: CGFloat = 232
        static let fieldHeight: CGFloat = 22
        static let rowHeight: CGFloat = 24
    }

    // MARK: Motion

    enum Motion {
        static let quick: Double = 0.12
        static let standard: Double = 0.18

        static func animation(_ duration: Double = standard, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: duration)
        }
    }

    // MARK: Colors

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } == true ? dark : light
        }
    }

    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    /// Warm paper in light mode, deep graphite in dark mode.
    static let canvasNS = dynamic("scrawl.canvas", light: hex(0xF6F4EF), dark: hex(0x17181B))
    /// Chrome surfaces: tool rail, status strip, sidebars.
    static let chromeNS = dynamic("scrawl.chrome", light: hex(0xEDEBE6), dark: hex(0x1E1F23))
    /// Raised surfaces: popovers, palette, frame artboards.
    static let elevatedNS = dynamic("scrawl.elevated", light: hex(0xFFFFFF), dark: hex(0x26272C))
    static let borderNS = dynamic("scrawl.border", light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.09))
    static let separatorNS = dynamic("scrawl.separator", light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.07))
    static let hoverNS = dynamic("scrawl.hover", light: NSColor(white: 0, alpha: 0.055), dark: NSColor(white: 1, alpha: 0.065))
    static let fieldNS = dynamic("scrawl.field", light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.055))
    /// Snap/alignment guides use a warm amber so they never read as selection.
    static let guideNS = dynamic("scrawl.guide", light: hex(0xE8820C), dark: hex(0xFFA23A))

    static var canvas: Color { Color(nsColor: canvasNS) }
    static var chrome: Color { Color(nsColor: chromeNS) }
    static var elevated: Color { Color(nsColor: elevatedNS) }
    static var border: Color { Color(nsColor: borderNS) }
    static var separator: Color { Color(nsColor: separatorNS) }
    static var hover: Color { Color(nsColor: hoverNS) }
    static var field: Color { Color(nsColor: fieldNS) }
    static var guide: Color { Color(nsColor: guideNS) }
    static var accent: Color { Color.accentColor }
    static var destructive: Color { Color(nsColor: .systemRed) }
    static var primaryText: Color { Color(nsColor: .labelColor) }
    static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
    static var tertiaryText: Color { Color(nsColor: .tertiaryLabelColor) }

    /// Selection uses the user's system accent color.
    static func selectionCG(highContrast: Bool) -> CGColor {
        let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return highContrast ? c.cgColor : c.cgColor
    }

    // MARK: Typography

    enum Font {
        static let sectionTitle = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let label = SwiftUI.Font.system(size: 11)
        static let value = SwiftUI.Font.system(size: 11).monospacedDigit()
        static let small = SwiftUI.Font.system(size: 10)
        static let status = SwiftUI.Font.system(size: 11, weight: .medium)
    }
}
