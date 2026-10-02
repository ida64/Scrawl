import AppKit

enum FillStyle: String, CaseIterable, Sendable { case solid, hachure, crossHatch }
enum StrokeStyle: String, CaseIterable, Sendable { case solid, dashed, dotted }
/// How elements are drawn. Precision is Scrawl's default; Ink is hand-drawn; Soft is a relaxed
/// whiteboard look with rounder geometry.
enum RenderStyle: String, CaseIterable, Sendable {
    case precision, ink, soft

    var title: String {
        switch self {
        case .precision: return "Precision"
        case .ink: return "Ink"
        case .soft: return "Soft"
        }
    }

    /// Accepts names written by earlier Scrawl versions.
    init?(persisted: String) {
        switch persisted {
        case "clean", "technical": self = .precision
        case "sketch": self = .ink
        default: self.init(rawValue: persisted)
        }
    }
}
enum Arrowhead: String, CaseIterable, Sendable { case none, arrow, triangle, dot, bar }
enum LineRouting: String, CaseIterable, Sendable { case straight, elbow, curved }
enum TextAlign: String, CaseIterable, Sendable { case left, center, right }

enum FontFamily: String, CaseIterable, Sendable {
    case sans, rounded, serif, mono, hand

    var displayName: String {
        switch self {
        case .sans: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        case .hand: return "Handwritten"
        }
    }
}

enum FontWeightOption: String, CaseIterable, Sendable {
    case regular, medium, bold

    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }
}

/// Visual properties shared by all element kinds. Not every property is meaningful for every
/// kind; the inspector only exposes the relevant subset.
struct ElementStyle: Hashable, Sendable {
    var strokeColor: DrawingColor = .ink
    var fillColor: DrawingColor = .clear
    var fillStyle: FillStyle = .solid
    var strokeWidth: Double = 1.5
    var strokeStyle: StrokeStyle = .solid
    var opacity: Double = 1
    var renderStyle: RenderStyle = .precision
    var cornerRadius: Double = 6
    var fontFamily: FontFamily = .sans
    /// A specific installed font chosen from the Fonts panel (overrides `fontFamily`).
    var fontName: String?
    var fontSize: Double = 18
    var fontWeight: FontWeightOption = .regular
    var textAlign: TextAlign = .left
    var lineHeight: Double = 1.2
    var startArrowhead: Arrowhead = .none
    var endArrowhead: Arrowhead = .triangle
    var routing: LineRouting = .straight

    static let `default` = ElementStyle()
}

extension ElementStyle {
    func font(scale: CGFloat = 1) -> NSFont {
        let size = CGFloat(max(1, fontSize)) * scale
        if let fontName, let custom = NSFont(name: fontName, size: size) {
            return fontWeight == .bold ? NSFontManager.shared.convert(custom, toHaveTrait: .boldFontMask) : custom
        }
        switch fontFamily {
        case .hand:
            if let f = NSFont(name: "ChalkboardSE-" + (fontWeight == .bold ? "Bold" : "Regular"), size: size) { return f }
            return NSFont(name: "Chalkboard SE", size: size) ?? .systemFont(ofSize: size)
        case .sans:
            return .systemFont(ofSize: size, weight: fontWeight.nsWeight)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: fontWeight.nsWeight)
            if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        case .serif:
            let base = NSFont.systemFont(ofSize: size, weight: fontWeight.nsWeight)
            if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
            return base
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: fontWeight.nsWeight)
        }
    }

    /// Human-readable typeface name for the inspector.
    var typefaceName: String {
        if let fontName { return NSFont(name: fontName, size: 12)?.displayName ?? fontName }
        return fontFamily.displayName
    }

    var nsTextAlignment: NSTextAlignment {
        switch textAlign {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }
}
