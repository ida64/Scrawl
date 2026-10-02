import AppKit

struct RenderOptions {
    var dark: Bool
    /// Current zoom, used for zoom-independent decorations (frame labels) and level-of-detail.
    var zoom: CGFloat = 1
    /// Elements not drawn (e.g. the text currently being edited).
    var hiddenIDs: Set<ElementID> = []
    var drawFrameLabels = true
    /// When true, image placeholders are drawn for missing assets.
    var showMissingAssets = true
    /// Simplify elements that are only a few pixels on screen (canvas only; never for export).
    var levelOfDetail = false
    /// Selected frames get a highlighted title tag.
    var selectedIDs: Set<ElementID> = []
}

/// Caches per-element render geometry keyed by content revision, so panning and moving never
/// regenerate paths. Sketch paths in particular are relatively expensive to build.
final class GeometryCache {
    private struct Entry {
        var revision: Int
        var size: CGSize
        var style: ElementStyle
        var geometry: RenderGeometry
    }

    private var entries: [ElementID: Entry] = [:]

    func geometry(for e: Element, revision: Int) -> RenderGeometry {
        if let c = entries[e.id], c.revision == revision, c.size == e.frame.size, c.style == e.style {
            return c.geometry
        }
        let g = ElementGeometry.build(e)
        entries[e.id] = Entry(revision: revision, size: e.frame.size, style: e.style, geometry: g)
        return g
    }

    func invalidate(_ ids: some Sequence<ElementID>) {
        for id in ids { entries[id] = nil }
    }

    func removeAll() { entries.removeAll() }
}

enum SceneRenderer {
    /// Draws elements (already in z-order) into a y-down context whose CTM maps world → device.
    static func draw(_ elements: [Element], scene: Scene?, frameLookup: (ElementID) -> Element?,
                     in ctx: CGContext, cache: GeometryCache?, assets: AssetStore, options: RenderOptions) {
        // Small on-screen elements are batched into one path per color; batches are flushed
        // before any full-detail element so z-order stays correct.
        var batch = LODBatch()
        for e in elements where !e.isHidden && !options.hiddenIDs.contains(e.id) {
            // Text has its own legibility-based detail level (by font size), so it's excluded here.
            if options.levelOfDetail && e.type != .image && !e.isFrame && !e.isText {
                let screen = max(e.frame.width, e.frame.height) * options.zoom
                if screen < 28 {
                    batch.add(e, tiny: screen < 4)
                    continue
                }
            }
            batch.flush(ctx, options: options)
            let clip = e.frameID.flatMap(frameLookup)?.frame
            if let clip {
                ctx.saveGState()
                ctx.clip(to: clip)
            }
            let revision = scene?.contentRevision(of: e.id) ?? 0
            let geometry = cache?.geometry(for: e, revision: revision) ?? ElementGeometry.build(e)
            drawElement(e, geometry: geometry, in: ctx, assets: assets, options: options)
            if clip != nil { ctx.restoreGState() }
        }
        batch.flush(ctx, options: options)
    }

    /// Accumulates simplified geometry for small elements.
    private struct LODBatch {
        var strokes: [DrawingColor: CGMutablePath] = [:]
        var fills: [DrawingColor: CGMutablePath] = [:]
        var bars: [DrawingColor: CGMutablePath] = [:]
        var isEmpty = true

        mutating func add(_ e: Element, tiny: Bool) {
            isEmpty = false
            if tiny {
                let c = e.style.fillColor.isClear ? e.style.strokeColor : e.style.fillColor
                fills[c, default: CGMutablePath()].addRect(e.bounds)
                return
            }
            var t = CGAffineTransform(translationX: e.frame.minX, y: e.frame.minY)
            if e.rotation != 0 {
                t = CGAffineTransform(translationX: e.center.x, y: e.center.y).rotated(by: e.rotation)
                    .translatedBy(x: -e.frame.width / 2, y: -e.frame.height / 2)
            }
            if e.isText {
                let r = CGRect(origin: .zero, size: e.frame.size).insetBy(dx: 0, dy: e.frame.height * 0.2)
                bars[e.style.strokeColor, default: CGMutablePath()].addRect(r, transform: t)
                return
            }
            let outline: CGPath
            if case let .freehand(d) = e.kind {
                let p = CGMutablePath()
                p.addLines(between: d.points)
                outline = p
            } else {
                outline = ElementGeometry.outline(e)
            }
            if e.supportsFill && !e.style.fillColor.isClear {
                fills[e.style.fillColor, default: CGMutablePath()].addPath(outline, transform: t)
            }
            strokes[e.style.strokeColor, default: CGMutablePath()].addPath(outline, transform: t)
        }

        mutating func flush(_ ctx: CGContext, options: RenderOptions) {
            guard !isEmpty else { return }
            let dark = options.dark
            for (c, p) in fills {
                ctx.addPath(p)
                ctx.setFillColor(c.cgColor(dark: dark))
                ctx.fillPath()
            }
            for (c, p) in bars {
                ctx.addPath(p)
                ctx.setFillColor(c.cgColor(dark: dark).copy(alpha: 0.35) ?? c.cgColor(dark: dark))
                ctx.fillPath()
            }
            ctx.setLineWidth(1.25 / max(options.zoom, 0.01))
            ctx.setLineJoin(.round)
            ctx.setLineDash(phase: 0, lengths: [])
            for (c, p) in strokes {
                ctx.addPath(p)
                ctx.setStrokeColor(c.cgColor(dark: dark))
                ctx.strokePath()
            }
            strokes.removeAll(keepingCapacity: true)
            fills.removeAll(keepingCapacity: true)
            bars.removeAll(keepingCapacity: true)
            isEmpty = true
        }
    }

    static func applyElementTransform(_ e: Element, _ ctx: CGContext) {
        ctx.translateBy(x: e.frame.minX, y: e.frame.minY)
        if e.rotation != 0 {
            ctx.translateBy(x: e.frame.width / 2, y: e.frame.height / 2)
            ctx.rotate(by: e.rotation)
            ctx.translateBy(x: -e.frame.width / 2, y: -e.frame.height / 2)
        }
    }

    static func drawElement(_ e: Element, geometry g: RenderGeometry, in ctx: CGContext, assets: AssetStore, options: RenderOptions) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        applyElementTransform(e, ctx)

        let opacity = CGFloat(max(0, min(1, e.style.opacity)))
        let layered = opacity < 1
        if layered {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if layered { ctx.endTransparencyLayer() } }

        let dark = options.dark
        let style = e.style
        let sw = CGFloat(style.strokeWidth)
        // Soft mode mutes ink slightly for a relaxed whiteboard feel.
        let softAlpha: CGFloat = style.renderStyle == .soft ? 0.86 : 1
        let baseStroke = style.strokeColor.cgColor(dark: dark)
        let strokeColor = baseStroke.copy(alpha: baseStroke.alpha * softAlpha) ?? baseStroke

        switch e.kind {
        case let .text(t):
            drawText(t, e: e, ctx: ctx, color: style.strokeColor.nsColor(dark: dark), zoom: options.zoom)
            return
        case let .image(img):
            drawImage(img, e: e, ctx: ctx, assets: assets, options: options)
            return
        case let .frame(f):
            drawFrame(f, e: e, geometry: g, ctx: ctx, options: options)
            return
        default:
            break
        }

        // Fill
        if let area = g.fillArea, !style.fillColor.isClear {
            if let hatch = g.hatch {
                ctx.saveGState()
                ctx.addPath(area)
                ctx.clip()
                ctx.addPath(hatch)
                ctx.setStrokeColor(hatchColor(style.fillColor, dark: dark))
                ctx.setLineWidth(max(1, sw * 0.6))
                ctx.setLineCap(.round)
                ctx.strokePath()
                ctx.restoreGState()
            } else {
                ctx.addPath(area)
                ctx.setFillColor(style.fillColor.cgColor(dark: dark))
                ctx.fillPath()
            }
        }

        // Stroke
        configureStroke(ctx, style: style)
        if let stroke = g.stroke, sw > 0 {
            ctx.addPath(stroke)
            ctx.setStrokeColor(strokeColor)
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        if let heads = g.heads {
            ctx.addPath(heads)
            ctx.setStrokeColor(strokeColor)
            ctx.strokePath()
        }
        if let solid = g.strokeFill {
            ctx.addPath(solid)
            ctx.setFillColor(strokeColor)
            ctx.fillPath()
        }
    }

    static func configureStroke(_ ctx: CGContext, style: ElementStyle) {
        let sw = CGFloat(style.strokeWidth)
        ctx.setLineWidth(sw)
        if style.renderStyle == .precision {
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.miter)
        } else {
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
        }
        switch style.strokeStyle {
        case .solid: ctx.setLineDash(phase: 0, lengths: [])
        case .dashed: ctx.setLineDash(phase: 0, lengths: dashPattern(style))
        case .dotted:
            ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: dashPattern(style))
        }
    }

    static func dashPattern(_ style: ElementStyle) -> [CGFloat] {
        let sw = CGFloat(style.strokeWidth)
        switch style.strokeStyle {
        case .solid: return []
        case .dashed: return [max(6, sw * 4), max(6, sw * 3.5)]
        case .dotted: return [0.01, max(4, sw * 2.6)]
        }
    }

    static func hatchColor(_ c: DrawingColor, dark: Bool) -> CGColor {
        if case let .rgba(r, g, b, a) = c { return CGColor(srgbRed: r, green: g, blue: b, alpha: max(a, 0.8)) }
        return c.cgColor(dark: dark)
    }

    private static func drawText(_ t: TextData, e: Element, ctx: CGContext, color: NSColor, zoom: CGFloat) {
        let rect = CGRect(origin: .zero, size: e.frame.size)
        // Level of detail: text too small to read is drawn as soft bars.
        if CGFloat(e.style.fontSize) * zoom < 3 {
            ctx.setFillColor(color.withAlphaComponent(0.35).cgColor)
            ctx.fill(rect.insetBy(dx: 0, dy: rect.height * 0.2))
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        TextLayout.draw(t.text, style: e.style, in: rect, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawImage(_ img: ImageData, e: Element, ctx: CGContext, assets: AssetStore, options: RenderOptions) {
        let rect = CGRect(origin: .zero, size: e.frame.size)
        guard let image = assets.image(img.assetID) else {
            guard options.showMissingAssets else { return }
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.18))
            ctx.fill(rect)
            ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.6))
            ctx.setLineWidth(1 / max(options.zoom, 0.01))
            ctx.setLineDash(phase: 0, lengths: [4 / options.zoom, 4 / options.zoom])
            ctx.stroke(rect)
            ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            ctx.move(to: CGPoint(x: rect.maxX, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: rect.maxY))
            ctx.strokePath()
            return
        }
        let size = image.size
        let c = img.crop
        let from = CGRect(x: c.minX * size.width, y: (1 - c.maxY) * size.height, width: c.width * size.width, height: c.height * size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current?.imageInterpolation = .high
        if e.style.cornerRadius > 0 {
            let rad = min(CGFloat(e.style.cornerRadius), min(rect.width, rect.height) / 2)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.clip()
        }
        image.draw(in: rect, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawFrame(_ f: FrameData, e: Element, geometry g: RenderGeometry, ctx: CGContext, options: RenderOptions) {
        let rect = CGRect(origin: .zero, size: e.frame.size)
        let dark = options.dark
        let z = max(options.zoom, 0.01)
        let radius = min(6 / z, min(rect.width, rect.height) / 4)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let fill: CGColor = e.style.fillColor.isClear ? CanvasTheme.artboard(dark: dark) : e.style.fillColor.cgColor(dark: dark)
        // Artboard surface with a soft, zoom-independent shadow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5 / z), blur: 10 / z,
                      color: CGColor(gray: 0, alpha: dark ? 0.45 : 0.10))
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.10) : CGColor(gray: 0, alpha: 0.10))
        ctx.setLineWidth(1 / z)
        ctx.strokePath()

        guard options.drawFrameLabels else { return }
        let selected = options.selectedIDs.contains(e.id)
        let name = f.name.isEmpty ? "Frame" : f.name
        let font = NSFont.systemFont(ofSize: 11 / z, weight: .semibold)
        let textColor: NSColor = selected ? .white : (dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.48))
        let attr = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: textColor])
        let label = frameLabelRect(for: e, zoom: options.zoom).offsetBy(dx: -e.frame.minX, dy: -e.frame.minY)
        let textSize = attr.size()
        if selected {
            // Selected frames present their title as an accent tag.
            let tag = CGRect(x: label.minX, y: label.minY, width: min(textSize.width + 12 / z, max(label.width, 40 / z)), height: label.height)
            ctx.addPath(CGPath(roundedRect: tag, cornerWidth: 4 / z, cornerHeight: 4 / z, transform: nil))
            ctx.setFillColor(CanvasTheme.selection(highContrast: false))
            ctx.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let inset: CGFloat = selected ? 6 / z : 0
        attr.draw(with: CGRect(x: label.minX + inset, y: label.minY + (label.height - textSize.height) / 2, width: label.width - inset, height: textSize.height + 2),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// World-space rect of a frame's name label (drawn above the frame at constant screen size).
    static func frameLabelRect(for e: Element, zoom: CGFloat) -> CGRect {
        let z = max(zoom, 0.01)
        let h = 18 / z
        return CGRect(x: e.frame.minX, y: e.frame.minY - h - 5 / z, width: max(e.frame.width, 40 / z), height: h)
    }
}
