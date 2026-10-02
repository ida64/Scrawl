import Foundation
import AppKit
import Testing
@testable import Scrawl

@Suite struct ExportTests {
    @Test func svgIsWellFormedVector() throws {
        let (drawing, assets) = SampleDocument.make()
        let scene = Scene(drawing: drawing)
        let data = try #require(ExportService.export(.drawing, format: .svg, scene: scene, assets: assets, options: ExportOptions()))
        let svg = String(decoding: data, as: UTF8.self)
        #expect(svg.hasPrefix("<?xml"))
        #expect(svg.contains("<path d=\"M"))
        #expect(svg.contains("<text"))
        #expect(svg.contains("data:image/png;base64,"))
        _ = try XMLDocument(data: data) // throws if malformed
    }

    @Test func svgEscapesText() throws {
        let scene = Scene(drawing: Drawing(elements: [text("a < b & \"c\"", at: .zero)]))
        let data = try #require(ExportService.export(.drawing, format: .svg, scene: scene, assets: AssetStore(), options: ExportOptions()))
        _ = try XMLDocument(data: data)
        #expect(String(decoding: data, as: UTF8.self).contains("a &lt; b &amp;"))
    }

    @Test func pngRespectsScaleAndTransparency() throws {
        let scene = Scene(drawing: Drawing(elements: [rect(0, 0, 100, 50, fill: DrawingColor(hex: "#ff0000"))]))
        var o = ExportOptions()
        o.scale = 3
        o.padding = 10
        o.transparentBackground = true
        let (els, clip) = ExportService.content(for: .drawing, scene: scene)
        let img = try #require(ExportService.renderImage(els, clip: clip, scene: scene, assets: AssetStore(), options: o))
        let bounds = try #require(ExportService.contentBounds(els, clip: clip, padding: 10))
        #expect(img.width == Int((bounds.width * 3).rounded(.up)))
        let rep = NSBitmapImageRep(cgImage: img)
        #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) == 0)
    }

    @Test func selectionAndFrameScopes() throws {
        let a = rect(0, 0, 10, 10), b = rect(500, 500, 10, 10)
        let frame = Element(kind: .frame(FrameData(name: "F")), frame: CGRect(x: 400, y: 400, width: 200, height: 200), style: ElementStyle(), seed: 1)
        var child = b
        child.frameID = frame.id
        let scene = Scene(drawing: Drawing(elements: [frame, a, child]))
        #expect(ExportService.content(for: .selection([a.id]), scene: scene).elements.map(\.id) == [a.id])
        let f = ExportService.content(for: .frame(frame.id), scene: scene)
        #expect(f.elements.map(\.id) == [child.id])
        #expect(f.clip == frame.frame)
        let pdf = try #require(ExportService.export(.frame(frame.id), format: .pdf, scene: scene, assets: AssetStore(), options: ExportOptions()))
        #expect(pdf.starts(with: Data("%PDF".utf8)))
    }

    @Test func jpegIsOpaque() throws {
        let scene = Scene(drawing: Drawing(elements: [rect(0, 0, 40, 40)]))
        var o = ExportOptions()
        o.transparentBackground = true
        let data = try #require(ExportService.export(.drawing, format: .jpeg, scene: scene, assets: AssetStore(), options: o))
        #expect(data.starts(with: [0xFF, 0xD8]))
    }
}

@Suite(.serialized) struct PerformanceTests {
    private func renderTime(_ count: Int, zoom: CGFloat) -> (ms: Double, drawn: Int) {
        let drawing = SyntheticScenes.make(count: count)
        let scene = Scene(drawing: drawing)
        let index = SpatialIndex()
        index.rebuild(scene.elements)
        let cache = GeometryCache()
        let size = CGSize(width: 1440, height: 900)
        let bounds = CGRect.union(scene.elements.map(\.bounds))!
        var v = CanvasViewport.fitting(bounds, viewSize: size)
        if zoom != 0 { v.zoom(to: zoom, anchor: CGPoint(x: 720, y: 450)) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 2880, height: 1800, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: 2, y: 2)
        func frame() -> Int {
            let ids = index.query(v.visibleWorldRect(viewSize: size))
            let els = ids.compactMap { id in scene.index(of: id).map { ($0, scene.elements[$0]) } }.sorted { $0.0 < $1.0 }.map(\.1)
            ctx.saveGState()
            ctx.concatenate(v.transform)
            SceneRenderer.draw(els, scene: scene, frameLookup: scene.element, in: ctx, cache: cache, assets: AssetStore(), options: { var o = RenderOptions(dark: true, zoom: v.zoom); o.levelOfDetail = true; return o }())
            ctx.restoreGState()
            return els.count
        }
        _ = frame() // warm the geometry cache, like the first frame on screen
        let start = CACurrentMediaTime()
        var drawn = 0
        for _ in 0..<5 { drawn = frame(); v.pan(byScreenDelta: CGPoint(x: 3, y: 2)) }
        return ((CACurrentMediaTime() - start) / 5 * 1000, drawn)
    }

    @Test(arguments: [1_000, 5_000, 10_000])
    func renderingAtTypicalZoomStaysInteractive(count: Int) {
        let r = renderTime(count, zoom: 1)
        print("render \(count) @100%: \(String(format: "%.2f", r.ms)) ms, \(r.drawn) visible")
        #expect(r.ms < 16, "frame budget exceeded: \(r.ms) ms")
    }

    @Test(arguments: [1_000, 10_000])
    func renderingWholeSceneZoomedOut(count: Int) {
        let r = renderTime(count, zoom: 0)
        print("render \(count) fit-all: \(String(format: "%.2f", r.ms)) ms, \(r.drawn) visible")
        #expect(r.drawn == count)
        #expect(r.ms < 50, "fit-all frame too slow: \(r.ms) ms")
    }

    @Test func hitTestingIsFastIn10k() {
        let scene = Scene(drawing: SyntheticScenes.make(count: 10_000))
        let index = SpatialIndex()
        index.rebuild(scene.elements)
        let start = CACurrentMediaTime()
        var hits = 0
        for i in 0..<1000 {
            let p = CGPoint(x: Double(i % 100) * 160 + 30, y: Double(i / 100) * 130 + 30)
            for id in index.query(CGRect(center: p, size: CGSize(width: 10, height: 10))) {
                if let e = scene.element(id), HitTester.hits(e, p, tolerance: 4) { hits += 1 }
            }
        }
        let ms = (CACurrentMediaTime() - start) * 1000 / 1000
        print("hit test avg: \(String(format: "%.3f", ms)) ms")
        #expect(ms < 1)
    }

    @Test func draggingManyElementsUpdatesIncrementally() {
        let scene = Scene(drawing: SyntheticScenes.make(count: 10_000))
        let ids = Set(scene.elements.prefix(500).map(\.id))
        scene.beginTransaction()
        let start = CACurrentMediaTime()
        for _ in 0..<10 { SceneOps.translate(ids, by: CGPoint(x: 1, y: 1), in: scene) }
        let ms = (CACurrentMediaTime() - start) * 1000 / 10
        _ = scene.commitTransaction()
        print("translate 500 of 10k: \(String(format: "%.2f", ms)) ms/step")
        #expect(ms < 16)
    }
}
