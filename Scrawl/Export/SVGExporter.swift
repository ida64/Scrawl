import AppKit

/// Writes vector SVG from the same geometry the canvas renders, so sketch strokes match exactly.
enum SVGExporter {
    static func svg(_ elements: [Element], clip: CGRect?, scene: Scene, assets: AssetStore, options: ExportOptions) -> String {
        guard let bounds = ExportService.contentBounds(elements, clip: clip, padding: options.padding) else {
            return #"<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"/>"#
        }
        var out = ""
        let w = num(bounds.width), h = num(bounds.height)
        out += #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        out += #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="\#(w)" height="\#(h)" viewBox="\#(num(bounds.minX)) \#(num(bounds.minY)) \#(w) \#(h)">"# + "\n"
        out += "<!-- Created with Scrawl -->\n"
        var defs = ""
        var body = ""
        if !options.transparentBackground {
            body += #"<rect x="\#(num(bounds.minX))" y="\#(num(bounds.minY))" width="\#(w)" height="\#(h)" fill="\#(color(options.backgroundColor()))"/>"# + "\n"
        }
        var clipIDs: [ElementID: String] = [:]
        func frameClip(_ id: ElementID) -> String? {
            if let c = clipIDs[id] { return c }
            guard let f = scene.element(id) else { return nil }
            let cid = "frame-\(clipIDs.count)"
            clipIDs[id] = cid
            defs += #"<clipPath id="\#(cid)"><rect x="\#(num(f.frame.minX))" y="\#(num(f.frame.minY))" width="\#(num(f.frame.width))" height="\#(num(f.frame.height))"/></clipPath>"# + "\n"
            return cid
        }
        if let clip {
            defs += #"<clipPath id="export-clip"><rect x="\#(num(clip.minX))" y="\#(num(clip.minY))" width="\#(num(clip.width))" height="\#(num(clip.height))"/></clipPath>"# + "\n"
            body += #"<g clip-path="url(#export-clip)">"# + "\n"
        }
        for (i, e) in elements.enumerated() {
            let clipAttr = e.frameID.flatMap(frameClip).map { #" clip-path="url(#\#($0))""# } ?? ""
            body += "<g\(clipAttr)>" + element(e, index: i, assets: assets, options: options, defs: &defs) + "</g>\n"
        }
        if clip != nil { body += "</g>\n" }
        if !defs.isEmpty { out += "<defs>\n" + defs + "</defs>\n" }
        out += body
        out += "</svg>\n"
        return out
    }

    // MARK: Elements

    private static func element(_ e: Element, index: Int, assets: AssetStore, options: ExportOptions, defs: inout String) -> String {
        let g = ElementGeometry.build(e)
        let dark = options.dark
        var transform = "translate(\(num(e.frame.minX)) \(num(e.frame.minY)))"
        if e.rotation != 0 {
            transform += " rotate(\(num(e.rotation * 180 / .pi)) \(num(e.frame.width / 2)) \(num(e.frame.height / 2)))"
        }
        var s = #"<g transform="\#(transform)""#
        if e.style.opacity < 1 { s += #" opacity="\#(num(CGFloat(e.style.opacity)))""# }
        s += ">"
        let style = e.style
        let stroke = color(style.strokeColor.cgColor(dark: dark))
        let sw = num(CGFloat(style.strokeWidth))
        let caps = style.renderStyle == .precision ? #"stroke-linecap="butt" stroke-linejoin="miter""# : #"stroke-linecap="round" stroke-linejoin="round""#
        let dash = SceneRenderer.dashPattern(style)
        let dashAttr = dash.isEmpty ? "" : #" stroke-dasharray="\#(dash.map { num($0) }.joined(separator: " "))""#

        switch e.kind {
        case let .text(t):
            s += text(t, e: e, color: stroke)
        case let .image(img):
            s += image(img, e: e, assets: assets, index: index, defs: &defs)
        case let .frame(f):
            let rect = CGRect(origin: .zero, size: e.frame.size)
            s += #"<rect x="0" y="0" width="\#(num(rect.width))" height="\#(num(rect.height))" rx="6" fill="\#(color(CanvasTheme.artboard(dark: dark)))" stroke="\#(dark ? "rgba(255,255,255,0.10)" : "rgba(0,0,0,0.10)")" stroke-width="1"/>"#
            s += #"<text x="0" y="-6" font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="11" font-weight="600" fill="\#(dark ? "rgba(255,255,255,0.55)" : "rgba(0,0,0,0.5)")">\#(escape(f.name))</text>"#
        default:
            if let area = g.fillArea, !style.fillColor.isClear {
                if let hatch = g.hatch {
                    let cid = "fill-\(index)"
                    defs += #"<clipPath id="\#(cid)"><path d="\#(pathData(area))"/></clipPath>"# + "\n"
                    s += #"<path d="\#(pathData(hatch))" fill="none" stroke="\#(color(SceneRenderer.hatchColor(style.fillColor, dark: dark)))" stroke-width="\#(num(max(1, CGFloat(style.strokeWidth) * 0.6)))" stroke-linecap="round" clip-path="url(#\#(cid))"/>"#
                } else {
                    s += #"<path d="\#(pathData(area))" fill="\#(color(style.fillColor.cgColor(dark: dark)))"/>"#
                }
            }
            if let p = g.stroke, style.strokeWidth > 0 {
                s += #"<path d="\#(pathData(p))" fill="none" stroke="\#(stroke)" stroke-width="\#(sw)" \#(caps)\#(dashAttr)/>"#
            }
            if let p = g.heads {
                s += #"<path d="\#(pathData(p))" fill="none" stroke="\#(stroke)" stroke-width="\#(sw)" \#(caps)/>"#
            }
            if let p = g.strokeFill {
                s += #"<path d="\#(pathData(p))" fill="\#(stroke)" fill-rule="nonzero"/>"#
            }
        }
        s += "</g>"
        return s
    }

    private static func text(_ t: TextData, e: Element, color: String) -> String {
        let style = e.style
        let font = style.font()
        let storage = NSTextStorage(string: t.text.isEmpty ? " " : t.text, attributes: TextLayout.attributes(style, color: .black))
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: e.frame.width + 0.5, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var family: String
        switch style.fontFamily {
        case .hand: family = "'Chalkboard SE', 'Comic Sans MS', 'Segoe Print', cursive"
        case .sans: family = "-apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif"
        case .rounded: family = "'SF Pro Rounded', ui-rounded, 'Helvetica Neue', Arial, sans-serif"
        case .serif: family = "'New York', Georgia, 'Times New Roman', serif"
        case .mono: family = "'SF Mono', Menlo, Consolas, monospace"
        }
        if let custom = style.fontName { family = "'\(font.familyName ?? custom)', " + family }
        let weight = style.fontWeight == .bold ? "700" : style.fontWeight == .medium ? "500" : "400"
        let anchor: String
        let x: CGFloat
        switch style.textAlign {
        case .left: anchor = "start"; x = 0
        case .center: anchor = "middle"; x = e.frame.width / 2
        case .right: anchor = "end"; x = e.frame.width
        }
        var out = #"<text font-family="\#(escape(family))" font-size="\#(num(font.pointSize))" font-weight="\#(weight)" fill="\#(color)" text-anchor="\#(anchor)" xml:space="preserve">"#
        let ns = storage.string as NSString
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { rect, _, _, glyphRange, _ in
            let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let line = ns.substring(with: charRange).trimmingCharacters(in: .newlines)
            let baseline = rect.minY + layout.location(forGlyphAt: glyphRange.location).y
            out += #"<tspan x="\#(num(x))" y="\#(num(baseline))">\#(escape(line))</tspan>"#
        }
        out += "</text>"
        return out
    }

    private static func image(_ img: ImageData, e: Element, assets: AssetStore, index: Int, defs: inout String) -> String {
        guard let asset = assets.asset(img.assetID), let natural = assets.naturalSize(img.assetID) else { return "" }
        let mime: String
        switch asset.fileExtension.lowercased() {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "svg": mime = "image/svg+xml"
        case "webp": mime = "image/webp"
        default: mime = "image/png"
        }
        var data = asset.data
        // Formats browsers can't display (HEIC/TIFF) are converted to PNG.
        if ["heic", "heif", "tiff", "tif", "bmp"].contains(asset.fileExtension.lowercased()),
           let rep = NSImage(data: asset.data).flatMap({ $0.tiffRepresentation }).flatMap(NSBitmapImageRep.init(data:)),
           let png = rep.representation(using: .png, properties: [:]) {
            data = png
        }
        let c = img.crop
        let vb = "\(num(c.minX * natural.width)) \(num(c.minY * natural.height)) \(num(c.width * natural.width)) \(num(c.height * natural.height))"
        var s = #"<svg x="0" y="0" width="\#(num(e.frame.width))" height="\#(num(e.frame.height))" viewBox="\#(vb)" preserveAspectRatio="none">"#
        s += #"<image width="\#(num(natural.width))" height="\#(num(natural.height))" preserveAspectRatio="none" href="data:\#(mime);base64,\#(data.base64EncodedString())"/>"#
        s += "</svg>"
        return s
    }

    // MARK: Helpers

    static func pathData(_ path: CGPath) -> String {
        var d = ""
        path.applyWithBlock { ptr in
            let el = ptr.pointee
            let p = el.points
            switch el.type {
            case .moveToPoint: d += "M\(num(p[0].x)) \(num(p[0].y))"
            case .addLineToPoint: d += "L\(num(p[0].x)) \(num(p[0].y))"
            case .addQuadCurveToPoint: d += "Q\(num(p[0].x)) \(num(p[0].y)) \(num(p[1].x)) \(num(p[1].y))"
            case .addCurveToPoint: d += "C\(num(p[0].x)) \(num(p[0].y)) \(num(p[1].x)) \(num(p[1].y)) \(num(p[2].x)) \(num(p[2].y))"
            case .closeSubpath: d += "Z"
            @unknown default: break
            }
        }
        return d
    }

    static func num(_ v: CGFloat) -> String {
        guard v.isFinite else { return "0" }
        let r = (Double(v) * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        return String(format: "%.2f", r).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func color(_ c: CGColor) -> String {
        let conv = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? c
        let comps = conv.components ?? [0, 0, 0, 1]
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        if comps.count >= 4 { (r, g, b, a) = (comps[0], comps[1], comps[2], comps[3]) } else { (r, g, b, a) = (comps[0], comps[0], comps[0], comps.count > 1 ? comps[1] : 1) }
        let hex = String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        return a < 1 ? "\(hex)\(String(format: "%02x", Int((a * 255).rounded())))" : hex
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
