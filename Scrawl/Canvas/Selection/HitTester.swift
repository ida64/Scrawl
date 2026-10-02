import CoreGraphics
import Foundation

/// Precise, type-aware hit testing in world coordinates.
enum HitTester {
    /// Whether `world` hits element `e` within `tolerance` (world units).
    /// - Parameter selected: selected shapes are also hit inside their (unfilled) interiors.
    static func hits(_ e: Element, _ world: CGPoint, tolerance: CGFloat, selected: Bool = false) -> Bool {
        guard e.bounds.expanded(by: tolerance + CGFloat(e.style.strokeWidth)).contains(world) else { return false }
        let local = e.toLocal(world) - e.frame.origin
        let rect = CGRect(origin: .zero, size: e.frame.size)
        let sw = CGFloat(e.style.strokeWidth)
        switch e.kind {
        case .text, .image:
            return rect.expanded(by: tolerance).contains(local)
        case .frame:
            // Frames are hit on their border; the interior belongs to their contents.
            if selected && rect.contains(local) { return true }
            return nearOutline(ElementGeometry.outline(e), local, width: tolerance * 2 + sw)
        case .rectangle, .ellipse, .diamond:
            let outline = ElementGeometry.outline(e)
            if (!e.style.fillColor.isClear || selected) && outline.contains(local) { return true }
            return nearOutline(outline, local, width: tolerance * 2 + sw)
        case let .line(d), let .arrow(d):
            let path = ElementGeometry.linearCenterline(d, routing: e.style.routing)
            for poly in path.flattenedPolylines(tolerance: 0.5) where Geometry.distance(from: local, toPolyline: poly) <= tolerance + sw / 2 + 2 {
                return true
            }
            return false
        case let .freehand(d):
            if d.points.count == 1 { return local.distance(to: d.points[0]) <= tolerance + sw * 2 }
            return Geometry.distance(from: local, toPolyline: d.points) <= tolerance + sw
        }
    }

    private static func nearOutline(_ path: CGPath, _ p: CGPoint, width: CGFloat) -> Bool {
        path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
    }

    /// Whether the element lies completely inside a world rect (marquee semantics).
    static func isEnclosed(_ e: Element, by rect: CGRect) -> Bool {
        rect.contains(e.bounds)
    }

    /// Whether the element's actual geometry intersects a world rect (used for ⌥-marquee "touch" selection).
    static func intersects(_ e: Element, rect: CGRect) -> Bool {
        guard e.bounds.intersects(rect) else { return false }
        if rect.contains(e.bounds) { return true }
        let poly = rect.corners
        // Rect corners inside the element?
        for c in poly where hits(e, c, tolerance: 0, selected: true) { return true }
        // Element outline crosses the rect?
        let outline = ElementGeometry.outline(e)
        var t = CGAffineTransform(translationX: e.frame.minX, y: e.frame.minY)
        if e.rotation != 0 {
            t = CGAffineTransform(translationX: e.center.x, y: e.center.y).rotated(by: e.rotation).translatedBy(x: -e.frame.width / 2, y: -e.frame.height / 2)
        }
        for line in outline.flattenedPolylines(tolerance: 2) {
            for p in line where rect.contains(p.applying(t)) { return true }
        }
        return false
    }
}
