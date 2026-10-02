import Foundation
import CoreGraphics
import Testing
@testable import Scrawl

@Suite struct GeometryTests {
    @Test func distanceToSegment() {
        #expect(Geometry.distance(from: CGPoint(x: 5, y: 5), toSegment: .zero, CGPoint(x: 10, y: 0)) == 5)
        #expect(Geometry.distance(from: CGPoint(x: -3, y: 4), toSegment: .zero, CGPoint(x: 10, y: 0)) == 5)
        #expect(abs(Geometry.distance(from: CGPoint(x: 1, y: 1), toSegment: .zero, .zero) - 2.squareRoot()) < 1e-12)
    }

    @Test func rotationAroundPivot() {
        let p = CGPoint(x: 10, y: 0).rotated(around: .zero, by: .pi / 2)
        #expect(p.isClose(to: CGPoint(x: 0, y: 10)))
        let q = CGPoint(x: 2, y: 1).rotated(around: CGPoint(x: 1, y: 1), by: .pi)
        #expect(q.isClose(to: CGPoint(x: 0, y: 1)))
    }

    @Test func polygonContainment() {
        let square = CGRect(x: 0, y: 0, width: 10, height: 10).corners
        #expect(Geometry.polygon(square, contains: CGPoint(x: 5, y: 5)))
        #expect(!Geometry.polygon(square, contains: CGPoint(x: 15, y: 5)))
        let diamond = Geometry.diamondPoints(in: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(!Geometry.polygon(diamond, contains: CGPoint(x: 1, y: 1)))
        #expect(Geometry.polygon(diamond, contains: CGPoint(x: 5, y: 2)))
    }

    @Test func segmentIntersection() {
        let p = Geometry.segmentIntersection(.zero, CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 0))
        #expect(p?.isClose(to: CGPoint(x: 5, y: 5)) == true)
        #expect(Geometry.segmentIntersection(.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)) == nil)
    }

    @Test func angleSnapping() {
        #expect(abs(Geometry.snapAngle(0.27) - .pi / 12) < 1e-9)
        let snapped = Geometry.snapPoint(CGPoint(x: 100, y: 3), from: .zero)
        #expect(snapped.isClose(to: CGPoint(x: CGPoint(x: 100, y: 3).length, y: 0), 1e-6))
    }

    @Test func boundingAndUnion() {
        #expect(CGRect.bounding([CGPoint(x: 1, y: 5), CGPoint(x: -2, y: 3)]) == CGRect(x: -2, y: 3, width: 3, height: 2))
        #expect(CGRect.bounding([CGPoint]()) == nil)
        #expect(CGRect.union([CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 5, y: 5, width: 1, height: 1)]) == CGRect(x: 0, y: 0, width: 6, height: 6))
    }

    @Test func rotatedBounds() {
        let r = CGRect(x: 0, y: 0, width: 10, height: 10).rotatedBounds(.pi / 4)
        let half = 10 * 2.squareRoot() / 2
        #expect(r.isClose(to: CGRect(x: 5 - half, y: 5 - half, width: half * 2, height: half * 2), 1e-6))
    }

    @Test func pathSimplificationKeepsEndpointsAndShape() {
        var pts: [CGPoint] = []
        for i in 0...100 { pts.append(CGPoint(x: CGFloat(i), y: 0.01 * CGFloat(i % 2))) }
        pts.append(CGPoint(x: 100, y: 50))
        let s = PathSmoothing.simplify(pts, epsilon: 0.5)
        #expect(s.first == pts.first)
        #expect(s.last == pts.last)
        #expect(s.count <= 4)
    }

    @Test func seededRandomIsDeterministic() {
        var a = SeededRandom(seed: 1234), b = SeededRandom(seed: 1234)
        for _ in 0..<100 { #expect(a.nextUInt32() == b.nextUInt32()) }
        var c = SeededRandom(seed: 99)
        for _ in 0..<1000 { let v = c.next(); #expect(v >= 0 && v < 1) }
    }

    @Test func sketchGeometryIsDeterministic() {
        var e = rect(0, 0, 120, 80)
        e.style.renderStyle = .ink
        e.style.fillColor = DrawingColor(hex: "#ff0000")
        let a = SVGExporter.pathData(ElementGeometry.build(e).stroke!)
        let b = SVGExporter.pathData(ElementGeometry.build(e).stroke!)
        #expect(a == b)
        e.seed = 8
        #expect(SVGExporter.pathData(ElementGeometry.build(e).stroke!) != a)
    }
}

@Suite struct ViewportTests {
    @Test func worldScreenRoundTrip() {
        let v = CanvasViewport(origin: CGPoint(x: -120.5, y: 330.25), zoom: 2.5)
        let w = CGPoint(x: 17.3, y: -42.9)
        #expect(v.toWorld(v.toScreen(w)).isClose(to: w, 1e-9))
        #expect(v.toScreen(v.origin) == .zero)
    }

    @Test func zoomKeepsAnchorFixed() {
        var v = CanvasViewport(origin: CGPoint(x: 100, y: 50), zoom: 1)
        let anchor = CGPoint(x: 300, y: 200)
        let before = v.toWorld(anchor)
        v.zoom(to: 3.7, anchor: anchor)
        #expect(v.toWorld(anchor).isClose(to: before, 1e-9))
        #expect(v.zoom == 3.7)
    }

    @Test func zoomIsClamped() {
        var v = CanvasViewport()
        v.zoom(to: 1000, anchor: .zero)
        #expect(v.zoom == CanvasViewport.maxZoom)
        v.zoom(to: 0, anchor: .zero)
        #expect(v.zoom == CanvasViewport.minZoom)
    }

    @Test func panMovesInScreenSpace() {
        var v = CanvasViewport(origin: .zero, zoom: 2)
        v.pan(byScreenDelta: CGPoint(x: 20, y: -10))
        #expect(v.origin.isClose(to: CGPoint(x: -10, y: 5)))
    }

    @Test func precisionFarFromOrigin() {
        let v = CanvasViewport(origin: CGPoint(x: 1e9, y: -1e9), zoom: 1.5)
        let w = CGPoint(x: 1e9 + 0.25, y: -1e9 + 0.5)
        #expect(v.toWorld(v.toScreen(w)).isClose(to: w, 1e-5))
    }

    @Test func fittingContainsRect() {
        let r = CGRect(x: -500, y: 200, width: 2000, height: 300)
        let size = CGSize(width: 1000, height: 700)
        let v = CanvasViewport.fitting(r, viewSize: size, padding: 50)
        let visible = v.visibleWorldRect(viewSize: size)
        #expect(visible.insetBy(dx: -0.01, dy: -0.01).contains(r))
        #expect(v.toScreen(r.center).isClose(to: CGPoint(x: 500, y: 350), 1e-6))
    }

    @Test func zoomSteps() {
        #expect(CanvasViewport.nextStep(after: 1) == 1.25)
        #expect(CanvasViewport.previousStep(before: 1) == 0.75)
    }
}
