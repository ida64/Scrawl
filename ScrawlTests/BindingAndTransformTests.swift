import Foundation
import CoreGraphics
import Testing
@testable import Scrawl

@Suite struct BindingTests {
    @Test func endpointLandsOnTargetEdgeWithGap() {
        let target = rect(200, 0, 100, 100)
        let p = BindingSolver.endpoint(binding: ConnectorBinding(elementID: target.id, anchor: CGPoint(x: 0.5, y: 0.5)),
                                       target: target, from: CGPoint(x: 0, y: 50), elbow: false)
        #expect(abs(p.x - (200 - BindingSolver.gap)) < 0.5)
        #expect(abs(p.y - 50) < 0.5)
    }

    @Test func movingTargetUpdatesBoundArrow() {
        let a = rect(0, 0, 100, 100), b = rect(300, 0, 100, 100)
        let arr = arrow(CGPoint(x: 105, y: 50), CGPoint(x: 295, y: 50),
                        start: ConnectorBinding(elementID: a.id, anchor: CGPoint(x: 0.5, y: 0.5)),
                        end: ConnectorBinding(elementID: b.id, anchor: CGPoint(x: 0.5, y: 0.5)))
        let h = Harness([a, b, arr])
        h.perform(MoveElementsCommand(ids: [b.id], delta: CGPoint(x: 0, y: 200)))
        let moved = h.scene.element(arr.id)!
        let end = moved.worldPoints.last!
        // The end now sits on b's boundary at its new position, and binding is preserved structurally.
        #expect(end.y > 150)
        #expect(moved.linear?.endBinding?.elementID == b.id)
        #expect(moved.linear?.startBinding?.elementID == a.id)
        h.undo.undo()
        #expect(h.scene.element(arr.id) == arr)
    }

    @Test func draggingArrowAloneDetachesIt() {
        let a = rect(0, 0, 100, 100)
        let arr = arrow(CGPoint(x: 105, y: 50), CGPoint(x: 300, y: 50), start: ConnectorBinding(elementID: a.id, anchor: CGPoint(x: 1, y: 0.5)))
        let h = Harness([a, arr])
        h.perform(MoveElementsCommand(ids: [arr.id], delta: CGPoint(x: 0, y: 300)))
        #expect(h.scene.element(arr.id)?.linear?.startBinding == nil)
    }

    @Test func movingBothKeepsBinding() {
        let a = rect(0, 0, 100, 100)
        let arr = arrow(CGPoint(x: 105, y: 50), CGPoint(x: 300, y: 50), start: ConnectorBinding(elementID: a.id, anchor: CGPoint(x: 1, y: 0.5)))
        let h = Harness([a, arr])
        h.perform(MoveElementsCommand(ids: [a.id, arr.id], delta: CGPoint(x: 0, y: 300)))
        #expect(h.scene.element(arr.id)?.linear?.startBinding?.elementID == a.id)
    }

    @Test func deletingTargetFreesConnector() {
        let a = rect(0, 0, 100, 100)
        let arr = arrow(CGPoint(x: 105, y: 50), CGPoint(x: 300, y: 50), start: ConnectorBinding(elementID: a.id, anchor: CGPoint(x: 1, y: 0.5)))
        let h = Harness([a, arr])
        h.perform(DeleteElementsCommand(ids: [a.id]))
        #expect(h.scene.element(arr.id)?.linear?.startBinding == nil)
        h.undo.undo()
        #expect(h.scene.element(arr.id)?.linear?.startBinding?.elementID == a.id)
    }

    @Test func elbowRouteIsOrthogonal() {
        let d = LinearData(points: [.zero, CGPoint(x: 100, y: 60)])
        let pts = ElementGeometry.route(d, routing: .elbow)
        for i in 1..<pts.count { #expect(pts[i].x == pts[i - 1].x || pts[i].y == pts[i - 1].y) }
        #expect(pts.first == .zero && pts.last == CGPoint(x: 100, y: 60))
    }

    @Test func bindingTargetSearch() {
        let a = rect(0, 0, 100, 100, fill: DrawingColor(hex: "#ff0000"))
        let scene = Scene(drawing: Drawing(elements: [a]))
        let hit = BindingSolver.target(at: CGPoint(x: 75, y: 50), in: scene, candidates: [a], excluding: [], tolerance: 5)
        #expect(hit?.0.id == a.id)
        #expect(hit.map { $0.1.isClose(to: CGPoint(x: 0.75, y: 0.5)) } == true)
        #expect(BindingSolver.target(at: CGPoint(x: 300, y: 300), in: scene, candidates: [a], excluding: [], tolerance: 5) == nil)
    }
}

@Suite struct TransformTests {
    @Test func cornerResizeKeepsOppositeCorner() {
        let r = rect(0, 0, 100, 50)
        let out = TransformMath.resize(r, handle: .bottomRight, to: CGPoint(x: 200, y: 150), keepAspect: false, fromCenter: false)
        #expect(out.frame.isClose(to: CGRect(x: 0, y: 0, width: 200, height: 150)))
    }

    @Test func shiftKeepsAspectRatio() {
        let r = rect(0, 0, 100, 50)
        let out = TransformMath.resize(r, handle: .bottomRight, to: CGPoint(x: 300, y: 60), keepAspect: true, fromCenter: false)
        #expect(abs(out.frame.width / out.frame.height - 2) < 1e-9)
        #expect(out.frame.origin.isClose(to: .zero))
    }

    @Test func optionResizesFromCenter() {
        let r = rect(0, 0, 100, 100)
        let out = TransformMath.resize(r, handle: .right, to: CGPoint(x: 150, y: 50), keepAspect: false, fromCenter: true)
        #expect(out.frame.isClose(to: CGRect(x: -50, y: 0, width: 200, height: 100)))
    }

    @Test func rotatedResizeKeepsAnchorFixedInWorld() {
        var r = rect(0, 0, 100, 50)
        r.rotation = 0.6
        let anchorBefore = r.toWorld(CGPoint(x: r.frame.minX, y: r.frame.minY))
        let target = r.toWorld(CGPoint(x: 180, y: 90))
        let out = TransformMath.resize(r, handle: .bottomRight, to: target, keepAspect: false, fromCenter: false)
        let anchorAfter = out.toWorld(CGPoint(x: out.frame.minX, y: out.frame.minY))
        #expect(anchorAfter.isClose(to: anchorBefore, 1e-6))
        #expect(abs(out.frame.width - 180) < 1e-6 && abs(out.frame.height - 90) < 1e-6)
    }

    @Test func draggingPastEdgeFlipsLine() {
        let l = arrow(.zero, CGPoint(x: 100, y: 0))
        let out = TransformMath.resize(l, handle: .right, to: CGPoint(x: -100, y: 0), keepAspect: false, fromCenter: false)
        let pts = out.worldPoints
        #expect(pts[0].x > pts[1].x)
    }

    @Test func multiScaleScalesPositionsAndSizes() {
        let a = rect(0, 0, 50, 50), b = rect(150, 50, 50, 50)
        let scene = Scene(drawing: Drawing(elements: [a, b]))
        TransformMath.scale([a, b], from: CGRect(x: 0, y: 0, width: 200, height: 100), to: CGRect(x: 0, y: 0, width: 400, height: 200), in: scene)
        #expect(scene.element(b.id)?.frame.isClose(to: CGRect(x: 300, y: 100, width: 100, height: 100)) == true)
    }

    @Test func groupRotationRotatesAroundSharedPivot() {
        let a = rect(0, 0, 10, 10), b = rect(90, 0, 10, 10)
        let scene = Scene(drawing: Drawing(elements: [a, b]))
        TransformMath.rotate([a.id, b.id], by: .pi, around: CGPoint(x: 50, y: 5), in: scene, originals: [a.id: a, b.id: b])
        #expect(scene.element(a.id)?.center.isClose(to: CGPoint(x: 95, y: 5), 1e-9) == true)
        #expect(abs(abs(scene.element(a.id)!.rotation) - .pi) < 1e-9)
    }

    @Test func textCornerScalesFont() {
        let t = text("Scale me", at: .zero)
        let out = TransformMath.resize(t, handle: .bottomRight, to: CGPoint(x: t.frame.width * 2, y: t.frame.height * 2), keepAspect: false, fromCenter: false)
        #expect(out.style.fontSize >= t.style.fontSize * 1.8)
    }

    @Test func croppingTrimsWithoutMovingContent() {
        let img = Element(kind: .image(ImageData(assetID: "a", crop: CGRect(x: 0, y: 0, width: 1, height: 1))),
                          frame: CGRect(x: 0, y: 0, width: 200, height: 100), style: ElementStyle(), seed: 1)
        let out = TransformMath.crop(img, handle: .left, to: CGPoint(x: 50, y: 50))
        #expect(out.frame.isClose(to: CGRect(x: 50, y: 0, width: 150, height: 100)))
        if case let .image(d) = out.kind { #expect(d.crop.isClose(to: CGRect(x: 0.25, y: 0, width: 0.75, height: 1))) }
        // Uncropped rect is unchanged, so the content didn't move.
        #expect(TransformMath.uncroppedRect(out)?.isClose(to: img.frame) == true)
        // Can't crop beyond the image.
        let over = TransformMath.crop(out, handle: .left, to: CGPoint(x: -500, y: 50))
        #expect(over.frame.isClose(to: img.frame))
    }
}
