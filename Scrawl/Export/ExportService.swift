import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case png, jpeg, pdf, svg

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .pdf: return .pdf
        case .svg: return .svg
        }
    }
    var isRaster: Bool { self == .png || self == .jpeg }
}

struct ExportOptions {
    var scale: CGFloat = 2
    var transparentBackground = false
    var padding: CGFloat = 24
    var dark = false
    var background: DrawingColor?

    func backgroundColor() -> CGColor {
        if let bg = background { return bg.cgColor(dark: dark) }
        return CanvasTheme.background(dark: dark)
    }
}

/// Renders scenes (or parts of them) to PNG, JPEG, PDF and SVG.
enum ExportService {
    /// Elements to export for a scope, in z-order, plus the clip rect for frame exports.
    static func content(for scope: ExportScope, scene: Scene) -> (elements: [Element], clip: CGRect?) {
        let (els, clip) = rawContent(for: scope, scene: scene)
        return (els.filter { !$0.isHidden }, clip)
    }

    private static func rawContent(for scope: ExportScope, scene: Scene) -> (elements: [Element], clip: CGRect?) {
        switch scope {
        case .drawing:
            return (scene.elements, nil)
        case let .selection(ids):
            return (scene.elements(SceneOps.expandFrames(ids, in: scene)), nil)
        case let .frame(id):
            guard let f = scene.element(id) else { return ([], nil) }
            let kids = scene.elements.filter { $0.frameID == id }
            return (kids, f.frame)
        }
    }

    static func contentBounds(_ elements: [Element], clip: CGRect?, padding: CGFloat) -> CGRect? {
        if let clip { return clip }
        guard let r = CGRect.union(elements.map { $0.isFrame ? $0.bounds : $0.renderBounds.insetBy(dx: 4, dy: 4) }) else { return nil }
        return r.expanded(by: padding)
    }

    // MARK: Raster

    static func renderImage(_ elements: [Element], clip: CGRect?, scene: Scene, assets: AssetStore, options: ExportOptions, opaque: Bool = false) -> CGImage? {
        guard let bounds = contentBounds(elements, clip: clip, padding: options.padding) else { return nil }
        let maxPixels: CGFloat = 16384
        var scale = max(0.1, options.scale)
        scale = min(scale, maxPixels / max(bounds.width, 1), maxPixels / max(bounds.height, 1))
        let w = max(1, Int((bounds.width * scale).rounded(.up)))
        let h = max(1, Int((bounds.height * scale).rounded(.up)))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        if !options.transparentBackground || opaque {
            ctx.setFillColor(options.backgroundColor())
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(elements, clip: clip, scene: scene, assets: assets, options: options, in: ctx, zoom: scale)
        return ctx.makeImage()
    }

    static func draw(_ elements: [Element], clip: CGRect?, scene: Scene, assets: AssetStore, options: ExportOptions, in ctx: CGContext, zoom: CGFloat) {
        if let clip { ctx.clip(to: clip) }
        var ro = RenderOptions(dark: options.dark)
        ro.zoom = max(zoom, 1)
        ro.drawFrameLabels = clip == nil
        ro.showMissingAssets = false
        SceneRenderer.draw(elements, scene: scene, frameLookup: { scene.element($0) }, in: ctx, cache: nil, assets: assets, options: ro)
    }

    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func jpegData(_ image: CGImage, quality: Double = 0.92) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // MARK: PDF

    static func pdfData(_ elements: [Element], clip: CGRect?, scene: Scene, assets: AssetStore, options: ExportOptions) -> Data? {
        guard let bounds = contentBounds(elements, clip: clip, padding: options.padding) else { return nil }
        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: bounds.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, [kCGPDFContextCreator as String: "Scrawl"] as CFDictionary) else { return nil }
        ctx.beginPDFPage(nil)
        if !options.transparentBackground {
            ctx.setFillColor(options.backgroundColor())
            ctx.fill(media)
        }
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        draw(elements, clip: clip, scene: scene, assets: assets, options: options, in: ctx, zoom: 1)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    // MARK: Entry point

    static func export(_ scope: ExportScope, format: ExportFormat, scene: Scene, assets: AssetStore, options: ExportOptions) -> Data? {
        let (elements, clip) = content(for: scope, scene: scene)
        guard !elements.isEmpty || clip != nil else { return nil }
        switch format {
        case .png:
            return renderImage(elements, clip: clip, scene: scene, assets: assets, options: options).flatMap { pngData($0) }
        case .jpeg:
            return renderImage(elements, clip: clip, scene: scene, assets: assets, options: options, opaque: true).flatMap { jpegData($0) }
        case .pdf:
            return pdfData(elements, clip: clip, scene: scene, assets: assets, options: options)
        case .svg:
            return SVGExporter.svg(elements, clip: clip, scene: scene, assets: assets, options: options).data(using: .utf8)
        }
    }

    /// Small thumbnail stored inside the package.
    static func previewPNG(scene: Scene, assets: AssetStore, dark: Bool) -> Data? {
        guard let b = contentBounds(scene.elements, clip: nil, padding: 24) else { return nil }
        var o = ExportOptions()
        o.dark = dark
        o.scale = min(2, 512 / max(b.width, b.height, 1))
        return renderImage(scene.elements, clip: nil, scene: scene, assets: assets, options: o).flatMap { pngData($0) }
    }
}

/// Canvas colors used by both the live canvas and exports.
enum CanvasTheme {
    /// Warm paper (light) / deep graphite (dark).
    static func background(dark: Bool) -> CGColor {
        dark ? CGColor(srgbRed: 0x17 / 255.0, green: 0x18 / 255.0, blue: 0x1B / 255.0, alpha: 1)
             : CGColor(srgbRed: 0xF6 / 255.0, green: 0xF4 / 255.0, blue: 0xEF / 255.0, alpha: 1)
    }

    static func gridColor(dark: Bool, major: Bool) -> CGColor {
        if dark { return CGColor(gray: 1, alpha: major ? 0.13 : 0.065) }
        return CGColor(srgbRed: 0.25, green: 0.22, blue: 0.16, alpha: major ? 0.16 : 0.075)
    }

    /// Frame artboards sit slightly above the canvas.
    static func artboard(dark: Bool) -> CGColor {
        dark ? CGColor(srgbRed: 0x1D / 255.0, green: 0x1E / 255.0, blue: 0x22 / 255.0, alpha: 1)
             : CGColor(srgbRed: 1, green: 1, blue: 0.995, alpha: 1)
    }

    /// Selection follows the user's system accent color.
    static func selection(highContrast: Bool) -> CGColor {
        ScrawlTheme.selectionCG(highContrast: highContrast)
    }

    static func guide(dark: Bool) -> CGColor {
        dark ? CGColor(srgbRed: 1, green: 0.64, blue: 0.23, alpha: 0.95) : CGColor(srgbRed: 0.91, green: 0.51, blue: 0.05, alpha: 0.95)
    }
}
