import Foundation
import CoreGraphics
import Testing
@testable import Scrawl

@Suite struct HitTestTests {
    @Test func unfilledShapeHitOnlyNearStroke() {
        let r = rect(0, 0, 100, 100)
        #expect(HitTester.hits(r, CGPoint(x: 1, y: 50), tolerance: 4))
        #expect(!HitTester.hits(r, CGPoint(x: 50, y: 50), tolerance: 4))
        // Selected shapes are grabbable from the inside.
        #expect(HitTester.hits(r, CGPoint(x: 50, y: 50), tolerance: 4, selected: true))
    }

    @Test func filledShapeHitInside() {
        let r = rect(0, 0, 100, 100, fill: DrawingColor(hex: "#ff0000"))
        #expect(HitTester.hits(r, CGPoint(x: 50, y: 50), tolerance: 4))
        #expect(!HitTester.hits(r, CGPoint(x: 150, y: 50), tolerance: 4))
    }

    @Test func ellipseUsesTrueShapeNotBox() {
        var e = ellipse(0, 0, 100, 100)
        e.style.fillColor = DrawingColor(hex: "#00ff00")
        #expect(HitTester.hits(e, CGPoint(x: 50, y: 50), tolerance: 1))
        #expect(!HitTester.hits(e, CGPoint(x: 3, y: 3), tolerance: 1))
    }

    @Test func diamondCornersAreEmpty() {
        var d = Element(kind: .diamond, frame: CGRect(x: 0, y: 0, width: 100, height: 100), style: ElementStyle(), seed: 1)
        d.style.fillColor = DrawingColor(hex: "#0000ff")
        #expect(!HitTester.hits(d, CGPoint(x: 5, y: 5), tolerance: 1))
        #expect(HitTester.hits(d, CGPoint(x: 50, y: 50), tolerance: 1))
    }

    @Test func rotatedElementHitInLocalSpace() {
        var r = rect(0, 0, 200, 20, fill: DrawingColor(hex: "#ff0000"))
        r.rotation = .pi / 2
        // After a 90° rotation around (100,10) the bar is vertical.
        #expect(HitTester.hits(r, CGPoint(x: 100, y: 90), tolerance: 1))
        #expect(!HitTester.hits(r, CGPoint(x: 180, y: 10), tolerance: 1))
    }

    @Test func lineHitAlongSegment() {
        let a = arrow(.zero, CGPoint(x: 100, y: 100))
        #expect(HitTester.hits(a, CGPoint(x: 52, y: 50), tolerance: 4))
        #expect(!HitTester.hits(a, CGPoint(x: 80, y: 20), tolerance: 4))
    }

    @Test func marqueeEnclosure() {
        let r = rect(10, 10, 20, 20)
        #expect(HitTester.isEnclosed(r, by: CGRect(x: 0, y: 0, width: 50, height: 50)))
        #expect(!HitTester.isEnclosed(r, by: CGRect(x: 0, y: 0, width: 25, height: 50)))
        #expect(HitTester.intersects(r, rect: CGRect(x: 0, y: 0, width: 12, height: 50)))
    }

    @Test func spatialIndexQueries() {
        let index = SpatialIndex(cellSize: 100)
        let a = rect(0, 0, 10, 10), b = rect(1000, 1000, 10, 10), big = rect(-50_000, -50_000, 100_000, 100_000)
        index.rebuild([a, b, big])
        let near = index.query(CGRect(x: -5, y: -5, width: 30, height: 30))
        #expect(near.contains(a.id) && near.contains(big.id) && !near.contains(b.id))
        index.remove(a.id)
        #expect(!index.query(CGRect(x: -5, y: -5, width: 30, height: 30)).contains(a.id))
        var moved = b
        moved.translate(by: CGPoint(x: -1000, y: -1000))
        index.insert(moved.id, moved.renderBounds)
        #expect(index.query(CGRect(x: -5, y: -5, width: 30, height: 30)).contains(b.id))
    }
}

@Suite struct SnapTests {
    @Test func snapsEdgesWithinTolerance() {
        let engine = SnapEngine(tolerance: 5, gridSpacing: nil)
        let r = engine.snap(moving: CGRect(x: 103, y: 300, width: 50, height: 50), against: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        #expect(r.offset.x == -3)
        #expect(r.offset.y == 0)
        #expect(!r.guides.isEmpty)
    }

    @Test func snapsCenters() {
        let engine = SnapEngine(tolerance: 5, gridSpacing: nil)
        let r = engine.snap(moving: CGRect(x: 27, y: 300, width: 50, height: 50), against: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        #expect(r.offset.x == -2) // center 52 → 50
    }

    @Test func ignoresFarTargets() {
        let engine = SnapEngine(tolerance: 5, gridSpacing: nil)
        let r = engine.snap(moving: CGRect(x: 120, y: 300, width: 50, height: 50), against: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        #expect(r.offset == .zero)
    }

    @Test func gridSnapping() {
        let engine = SnapEngine(tolerance: 5, gridSpacing: 20)
        let r = engine.snap(point: CGPoint(x: 47, y: 52), against: [])
        #expect(r.offset.isClose(to: CGPoint(x: -7, y: 8)))
    }

    @Test func equalSpacingHint() {
        let engine = SnapEngine(tolerance: 6, gridSpacing: nil)
        let left = CGRect(x: 0, y: 0, width: 100, height: 50), right = CGRect(x: 300, y: 0, width: 100, height: 50)
        // Moving box 50 wide between them; equal spacing puts it at x = 175.
        let r = engine.snap(moving: CGRect(x: 172, y: 10, width: 50, height: 30), against: [left, right])
        #expect(abs(r.offset.x - 3) < 0.001)
        #expect(r.guides.contains { if case .spacing = $0 { return true }; return false })
    }

    @Test func disabledObjectSnapping() {
        var engine = SnapEngine(tolerance: 5, gridSpacing: nil)
        engine.snapToObjects = false
        let r = engine.snap(moving: CGRect(x: 103, y: 300, width: 50, height: 50), against: [CGRect(x: 0, y: 0, width: 100, height: 100)])
        #expect(r.offset == .zero)
    }
}
