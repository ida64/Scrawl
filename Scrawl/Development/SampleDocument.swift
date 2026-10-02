import AppKit

/// A tour drawing that exercises shapes, connectors, text, colors, sketch/clean/technical
/// styles, frames, images, groups and alignment. Used for visual validation and as onboarding.
enum SampleDocument {
    private static func style(_ f: (inout ElementStyle) -> Void) -> ElementStyle {
        var s = ElementStyle()
        f(&s)
        return s
    }

    private static func shape(_ kind: ElementKind, _ r: CGRect, seed: UInt32, _ f: (inout ElementStyle) -> Void = { _ in }) -> Element {
        Element(kind: kind, frame: r, style: style(f), seed: seed)
    }

    private static func text(_ s: String, at p: CGPoint, size: Double = 18, family: FontFamily = .sans, weight: FontWeightOption = .regular,
                             align: TextAlign = .left, color: DrawingColor = .ink, centered: Bool = false, seed: UInt32) -> Element {
        var e = Element(kind: .text(TextData(text: s, autoWidth: true)), frame: CGRect(origin: p, size: .zero),
                        style: style { $0.fontSize = size; $0.fontFamily = family; $0.fontWeight = weight; $0.textAlign = align; $0.strokeColor = color },
                        seed: seed)
        TextLayout.fit(&e)
        if centered { e.frame.origin = CGPoint(x: p.x - e.frame.width / 2, y: p.y - e.frame.height / 2) }
        return e
    }

    private static func arrow(from a: Element, _ ua: CGPoint, to b: Element, _ ub: CGPoint, seed: UInt32, _ f: (inout ElementStyle) -> Void = { _ in }) -> Element {
        let d = LinearData(points: [], startBinding: ConnectorBinding(elementID: a.id, anchor: ua), endBinding: ConnectorBinding(elementID: b.id, anchor: ub))
        var e = Element(kind: .arrow(d), frame: .zero, style: style(f), seed: seed)
        e.setLinearWorldPoints([BindingSolver.anchorPoint(d.startBinding!, target: a), BindingSolver.anchorPoint(d.endBinding!, target: b)])
        return e
    }

    static func make() -> (Drawing, AssetStore) {
        let assets = AssetStore()
        var els: [Element] = []
        let slate = DrawingColor(hex: "#7d8590"), coral = DrawingColor(hex: "#e8705f"), amber = DrawingColor(hex: "#e3a03a")
        let fern = DrawingColor(hex: "#4caa6a"), lagoon = DrawingColor(hex: "#3aa29c"), cobalt = DrawingColor(hex: "#4a7fe0")
        let iris = DrawingColor(hex: "#8a6fe0")
        func tint(_ hex: String) -> DrawingColor { DrawingColor(hex: hex + "33") }

        let overview = Element(kind: .frame(FrameData(name: "System overview")), frame: CGRect(x: 0, y: 0, width: 1080, height: 560),
                               style: style { $0.fillColor = .clear }, seed: 1)
        let modes = Element(kind: .frame(FrameData(name: "Three styles")), frame: CGRect(x: 1140, y: 0, width: 620, height: 560),
                            style: style { $0.fillColor = .clear }, seed: 2)

        // Title
        els.append(text("Scrawl", at: CGPoint(x: 40, y: 36), size: 34, family: .sans, weight: .bold, seed: 3))
        els.append(text("Select anything to edit it in the inspector. ⌘K finds every command.",
                        at: CGPoint(x: 42, y: 84), size: 14, family: .sans, color: slate, seed: 4))

        // Architecture diagram (Precision).
        func node(_ r: CGRect, _ hex: String, _ seed: UInt32) -> Element {
            shape(.rectangle, r, seed: seed) { $0.strokeColor = DrawingColor(hex: hex); $0.fillColor = tint(hex); $0.cornerRadius = 8 }
        }
        let client = node(CGRect(x: 60, y: 180, width: 170, height: 76), "#4a7fe0", 10)
        let api = node(CGRect(x: 340, y: 180, width: 170, height: 76), "#8a6fe0", 11)
        let db = shape(.ellipse, CGRect(x: 640, y: 168, width: 170, height: 100), seed: 12) { $0.strokeColor = lagoon; $0.fillColor = tint("#3aa29c") }
        let cache = shape(.diamond, CGRect(x: 355, y: 340, width: 140, height: 104), seed: 13) { $0.strokeColor = amber; $0.fillColor = tint("#e3a03a"); $0.cornerRadius = 4 }
        let queue = node(CGRect(x: 640, y: 352, width: 170, height: 76), "#4caa6a", 14)
        els += [client, api, db, cache, queue]
        for (e, label, sd) in [(client, "Mac app", 20), (api, "API", 21), (db, "Database", 22), (cache, "Cache", 23), (queue, "Jobs", 24)] {
            els.append(text(label, at: e.center, size: 15, family: .sans, weight: .medium, align: .center, centered: true, seed: UInt32(sd)))
        }
        els.append(arrow(from: client, CGPoint(x: 1, y: 0.5), to: api, CGPoint(x: 0, y: 0.5), seed: 30) { $0.strokeColor = slate })
        els.append(arrow(from: api, CGPoint(x: 1, y: 0.5), to: db, CGPoint(x: 0, y: 0.5), seed: 31) { $0.strokeColor = slate; $0.startArrowhead = .dot })
        els.append(arrow(from: api, CGPoint(x: 0.5, y: 1), to: cache, CGPoint(x: 0.5, y: 0), seed: 32) { $0.strokeColor = amber; $0.strokeStyle = .dashed })
        els.append(arrow(from: api, CGPoint(x: 0.85, y: 1), to: queue, CGPoint(x: 0, y: 0.5), seed: 33) { $0.strokeColor = fern; $0.routing = .elbow })
        els.append(text("reads", at: CGPoint(x: 548, y: 192), size: 12, family: .sans, color: slate, seed: 25))
        els.append(text("async", at: CGPoint(x: 560, y: 368), size: 12, family: .sans, color: fern, seed: 26))

        // A grouped note in Soft style.
        let gid = UUID()
        var note = shape(.rectangle, CGRect(x: 880, y: 170, width: 170, height: 120), seed: 70) {
            $0.strokeColor = amber; $0.fillColor = DrawingColor(hex: "#e3a03a40"); $0.renderStyle = .soft
        }
        note.groupIDs = [gid]
        var noteText = text("Group of shape\n+ text: moves\nas one (⇧⌘G).", at: CGPoint(x: 896, y: 186), size: 13, family: .rounded, seed: 71)
        noteText.groupIDs = [gid]
        els += [note, noteText]

        // Image and pen stroke.
        if let png = makeSampleImage(), let id = assets.add(data: png, fileExtension: "png") {
            els.append(Element(kind: .image(ImageData(assetID: id, crop: CGRect(x: 0, y: 0, width: 1, height: 1))),
                               frame: CGRect(x: 880, y: 330, width: 170, height: 113),
                               style: style { $0.strokeWidth = 0; $0.cornerRadius = 8 }, seed: 60))
        }
        var pts: [CGPoint] = []
        var prs: [Double] = []
        for i in 0...60 {
            let t = Double(i) / 60
            pts.append(CGPoint(x: t * 240, y: sin(t * .pi * 3) * 14))
            prs.append(0.35 + 0.5 * sin(t * .pi))
        }
        let pen = pts.map { $0 + CGPoint(x: 70, y: 480) }
        let penBox = CGRect.bounding(pen) ?? .zero
        els.append(Element(kind: .freehand(FreehandData(points: pen.map { $0 - penBox.origin }, pressures: prs)), frame: penBox,
                           style: style { $0.strokeColor = coral; $0.strokeWidth = 2.5 }, seed: 50))
        els.append(text("pen strokes keep their pressure", at: CGPoint(x: 330, y: 470), size: 12, family: .sans, color: coral, seed: 51))

        // The same three shapes in Precision, Ink and Soft.
        for (i, mode) in RenderStyle.allCases.enumerated() {
            let x = 1180 + CGFloat(i) * 190
            let c: DrawingColor = [cobalt, iris, fern][i]
            let hex = ["#4a7fe0", "#8a6fe0", "#4caa6a"][i]
            els.append(text(mode.title, at: CGPoint(x: x, y: 60), size: 15, family: .sans, weight: .bold, seed: UInt32(100 + i)))
            els.append(text(mode.subtitle, at: CGPoint(x: x, y: 84), size: 11, family: .sans, color: slate, seed: UInt32(110 + i)))
            els.append(shape(.rectangle, CGRect(x: x, y: 130, width: 150, height: 90), seed: UInt32(120 + i)) {
                $0.strokeColor = c; $0.fillColor = tint(hex); $0.renderStyle = mode; $0.cornerRadius = mode == .precision ? 8 : 0
                if mode == .ink { $0.fillStyle = .hachure }
            })
            els.append(shape(.ellipse, CGRect(x: x, y: 250, width: 150, height: 90), seed: UInt32(130 + i)) {
                $0.strokeColor = c; $0.renderStyle = mode
            })
            els.append(shape(.diamond, CGRect(x: x + 15, y: 370, width: 120, height: 100), seed: UInt32(140 + i)) {
                $0.strokeColor = c; $0.fillColor = tint(hex); $0.renderStyle = mode; $0.cornerRadius = 0
                if mode == .ink { $0.fillStyle = .crossHatch }
            })
        }

        // Assign frame membership and resolve connector endpoints.
        var all = [overview, modes] + els
        for i in all.indices where !all[i].isFrame {
            let c = all[i].bounds.center
            if overview.frame.contains(c) { all[i].frameID = overview.id } else if modes.frame.contains(c) { all[i].frameID = modes.id }
        }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        for i in all.indices where all[i].isLinear {
            if let solved = BindingSolver.solve(all[i], lookup: { byID[$0] }) { all[i] = solved }
        }
        var settings = Preferences.shared.defaultSettings
        settings.grid = .dots
        return (Drawing(elements: all, settings: settings), assets)
    }

    /// A small generated landscape so the sample works offline without bundled files.
    static func makeSampleImage() -> Data? {
        let w = 480, h = 320
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sky = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.98, green: 0.62, blue: 0.45, alpha: 1),
                                                         CGColor(srgbRed: 0.45, green: 0.42, blue: 0.85, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(h)), options: [])
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.88, blue: 0.55, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 300, y: 150, width: 90, height: 90))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.22, blue: 0.38, alpha: 1))
        ctx.move(to: CGPoint(x: 0, y: 0)); ctx.addLine(to: CGPoint(x: 0, y: 120)); ctx.addLine(to: CGPoint(x: 140, y: 210))
        ctx.addLine(to: CGPoint(x: 250, y: 110)); ctx.addLine(to: CGPoint(x: 360, y: 180)); ctx.addLine(to: CGPoint(x: 480, y: 90))
        ctx.addLine(to: CGPoint(x: 480, y: 0)); ctx.closePath(); ctx.fillPath()
        guard let img = ctx.makeImage() else { return nil }
        return ExportService.pngData(img)
    }
}
