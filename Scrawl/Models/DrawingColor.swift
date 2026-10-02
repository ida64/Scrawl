import AppKit

/// A color as stored in a drawing. `.ink` is the theme-adaptive foreground (near-white in dark
/// mode, near-black in light mode) so default drawings read well in both appearances.
enum DrawingColor: Hashable, Sendable {
    case ink
    case clear
    case rgba(r: Double, g: Double, b: Double, a: Double)

    init(hex: String) {
        self = DrawingColor.parse(hex) ?? .ink
    }

    static func parse(_ string: String) -> DrawingColor? {
        let s = string.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "ink" { return .ink }
        if s == "transparent" || s == "clear" || s == "none" { return .clear }
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        let has = hex.count == 8
        let r = Double((v >> (has ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (has ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (has ? 8 : 0)) & 0xFF) / 255
        let a = has ? Double(v & 0xFF) / 255 : 1
        return .rgba(r: r, g: g, b: b, a: a)
    }

    /// Serialized representation: "ink", "transparent", or "#rrggbb" / "#rrggbbaa".
    var serialized: String {
        switch self {
        case .ink: return "ink"
        case .clear: return "transparent"
        case let .rgba(r, g, b, a):
            func c(_ v: Double) -> String { String(format: "%02x", Int((max(0, min(1, v)) * 255).rounded())) }
            return "#" + c(r) + c(g) + c(b) + (a < 1 ? c(a) : "")
        }
    }

    var isClear: Bool {
        if case .clear = self { return true }
        if case let .rgba(_, _, _, a) = self, a <= 0 { return true }
        return false
    }

    func cgColor(dark: Bool) -> CGColor {
        switch self {
        case .ink: return dark ? CGColor(red: 0.91, green: 0.91, blue: 0.93, alpha: 1) : CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        case .clear: return CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        case let .rgba(r, g, b, a): return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
    }

    func nsColor(dark: Bool) -> NSColor { NSColor(cgColor: cgColor(dark: dark)) ?? .labelColor }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? NSColor.black
        self = .rgba(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }
}

/// Scrawl's palette: slightly softened tones that hold up on warm paper and deep graphite.
enum Palette {
    struct Entry {
        let name: String
        let hex: String
    }

    static let entries: [Entry] = [
        .init(name: "Slate", hex: "#7d8590"),
        .init(name: "Coral", hex: "#e8705f"),
        .init(name: "Amber", hex: "#e3a03a"),
        .init(name: "Fern", hex: "#4caa6a"),
        .init(name: "Lagoon", hex: "#3aa29c"),
        .init(name: "Cobalt", hex: "#4a7fe0"),
        .init(name: "Iris", hex: "#8a6fe0"),
        .init(name: "Orchid", hex: "#d06aa4"),
    ]

    static let stroke: [DrawingColor] = [.ink] + entries.map { DrawingColor(hex: $0.hex) }
    /// Fills are translucent tints of the same hues, so text and strokes stay readable on top.
    static let fill: [DrawingColor] = [.clear] + entries.map { DrawingColor(hex: $0.hex + "33") }

    static func name(for color: DrawingColor) -> String {
        switch color {
        case .ink: return "Ink"
        case .clear: return "None"
        case .rgba:
            let s = color.serialized
            let base = String(s.prefix(7))
            if let e = entries.first(where: { $0.hex == base }) { return s.count > 7 ? "\(e.name) tint" : e.name }
            return s.uppercased()
        }
    }
}
