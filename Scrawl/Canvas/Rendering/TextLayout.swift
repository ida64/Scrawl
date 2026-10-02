import AppKit

/// Measures and draws text elements. The same attributes are used by the inline editor so that
/// editing and rendering line up.
enum TextLayout {
    static func paragraphStyle(_ style: ElementStyle) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = style.nsTextAlignment
        p.lineBreakMode = .byWordWrapping
        p.lineHeightMultiple = CGFloat(max(0.6, min(3, style.lineHeight)))
        return p
    }

    static func attributes(_ style: ElementStyle, color: NSColor, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        [.font: style.font(scale: scale), .foregroundColor: color, .paragraphStyle: paragraphStyle(style)]
    }

    private struct Key: Hashable {
        let text: String
        let family: FontFamily
        let fontName: String?
        let lineHeight: Double
        let size: Double
        let weight: FontWeightOption
        let align: TextAlign
        let width: CGFloat?
    }

    private static var cache: [Key: CGSize] = [:]

    /// Size of the text box. With `wrapWidth == nil` the box is as wide as the longest line.
    static func measure(_ text: String, style: ElementStyle, wrapWidth: CGFloat?) -> CGSize {
        let key = Key(text: text, family: style.fontFamily, fontName: style.fontName, lineHeight: style.lineHeight, size: style.fontSize, weight: style.fontWeight,
                      align: style.textAlign, width: wrapWidth)
        if let s = cache[key] { return s }
        let measureText = text.isEmpty ? " " : (text.hasSuffix("\n") ? text + " " : text)
        let attr = NSAttributedString(string: measureText, attributes: attributes(style, color: .black))
        let bound = CGSize(width: wrapWidth ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let r = attr.boundingRect(with: bound, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: wrapWidth ?? ceil(max(r.width, CGFloat(style.fontSize) * 0.5)), height: ceil(r.height))
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = size
        return size
    }

    /// Recomputes a text element's frame size from its content and style.
    static func fit(_ e: inout Element) {
        guard case let .text(t) = e.kind else { return }
        let size = measure(t.text, style: e.style, wrapWidth: t.autoWidth ? nil : max(e.frame.width, 10))
        // Keep the center stable for rotated text so it doesn't drift while typing.
        if e.rotation != 0 {
            let oldTopLeft = e.toWorld(e.frame.origin)
            e.frame.size = size
            let newTopLeftIfSameOrigin = e.toWorld(e.frame.origin)
            e.frame.origin += oldTopLeft - newTopLeftIfSameOrigin
        } else {
            e.frame.size = size
        }
    }

    /// Draws text in local space. The current NSGraphicsContext must be flipped.
    static func draw(_ text: String, style: ElementStyle, in rect: CGRect, color: NSColor) {
        let attr = NSAttributedString(string: text, attributes: attributes(style, color: color))
        attr.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
