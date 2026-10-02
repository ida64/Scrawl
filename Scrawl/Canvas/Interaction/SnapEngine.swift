import CoreGraphics
import Foundation

/// A transient guide shown while snapping. Guides live only in the overlay, never in the document.
enum SnapGuide: Equatable {
    /// An alignment line between two world points.
    case line(CGPoint, CGPoint)
    /// Equal-spacing markers: each pair is a gap segment of identical length.
    case spacing([CGPoint])
}

struct SnapResult {
    var offset: CGPoint = .zero
    var guides: [SnapGuide] = []
}

/// Computes snapping offsets in world coordinates. Tolerance is supplied in world units by the
/// caller (screen tolerance / zoom), so snapping feels identical at every zoom level.
struct SnapEngine {
    var tolerance: CGFloat
    var gridSpacing: CGFloat?
    var snapToObjects = true

    // MARK: Moving a box

    func snap(moving box: CGRect, against others: [CGRect]) -> SnapResult {
        var result = SnapResult()
        let xs = [box.minX, box.midX, box.maxX]
        let ys = [box.minY, box.midY, box.maxY]

        var bestX: (delta: CGFloat, target: CGFloat)?
        var bestY: (delta: CGFloat, target: CGFloat)?
        if snapToObjects {
            for r in others {
                for t in [r.minX, r.midX, r.maxX] {
                    for s in xs {
                        let d = t - s
                        if abs(d) <= tolerance && abs(d) < abs(bestX?.delta ?? .infinity) { bestX = (d, t) }
                    }
                }
                for t in [r.minY, r.midY, r.maxY] {
                    for s in ys {
                        let d = t - s
                        if abs(d) <= tolerance && abs(d) < abs(bestY?.delta ?? .infinity) { bestY = (d, t) }
                    }
                }
            }
            // Equal spacing (only if no edge snap found on that axis).
            if bestX == nil, let eq = equalSpacing(box, others, horizontal: true) {
                result.offset.x = eq.delta
                result.guides.append(.spacing(eq.marks))
            }
            if bestY == nil, let eq = equalSpacing(box, others, horizontal: false) {
                result.offset.y = eq.delta
                result.guides.append(.spacing(eq.marks))
            }
        }
        if let g = gridSpacing, g > 0 {
            if bestX == nil && result.offset.x == 0 { result.offset.x = (box.minX / g).rounded() * g - box.minX }
            if bestY == nil && result.offset.y == 0 { result.offset.y = (box.minY / g).rounded() * g - box.minY }
        }
        if let bx = bestX { result.offset.x = bx.delta }
        if let by = bestY { result.offset.y = by.delta }

        // Build alignment guides for the final position.
        let moved = box.offsetBy(dx: result.offset.x, dy: result.offset.y)
        if let bx = bestX {
            var lo = moved.minY, hi = moved.maxY
            for r in others where [r.minX, r.midX, r.maxX].contains(where: { abs($0 - bx.target) < 0.01 }) {
                lo = min(lo, r.minY); hi = max(hi, r.maxY)
            }
            result.guides.append(.line(CGPoint(x: bx.target, y: lo), CGPoint(x: bx.target, y: hi)))
        }
        if let by = bestY {
            var lo = moved.minX, hi = moved.maxX
            for r in others where [r.minY, r.midY, r.maxY].contains(where: { abs($0 - by.target) < 0.01 }) {
                lo = min(lo, r.minX); hi = max(hi, r.maxX)
            }
            result.guides.append(.line(CGPoint(x: lo, y: by.target), CGPoint(x: hi, y: by.target)))
        }
        return result
    }

    /// Detects when the box sits between two neighbors with (nearly) equal gaps.
    private func equalSpacing(_ box: CGRect, _ others: [CGRect], horizontal: Bool) -> (delta: CGFloat, marks: [CGPoint])? {
        // Neighbors that overlap on the perpendicular axis.
        let overlapping = others.filter {
            horizontal ? ($0.maxY > box.minY && $0.minY < box.maxY) : ($0.maxX > box.minX && $0.minX < box.maxX)
        }
        let before = overlapping.filter { horizontal ? $0.maxX <= box.minX + tolerance : $0.maxY <= box.minY + tolerance }
            .max { horizontal ? $0.maxX < $1.maxX : $0.maxY < $1.maxY }
        let after = overlapping.filter { horizontal ? $0.minX >= box.maxX - tolerance : $0.minY >= box.maxY - tolerance }
            .min { horizontal ? $0.minX < $1.minX : $0.minY < $1.minY }
        guard let a = before, let b = after else { return nil }
        let gap1 = horizontal ? box.minX - a.maxX : box.minY - a.maxY
        let gap2 = horizontal ? b.minX - box.maxX : b.minY - box.maxY
        guard gap1 > 0, gap2 > 0 else { return nil }
        let delta = (gap2 - gap1) / 2
        guard abs(delta) <= tolerance else { return nil }
        let moved = horizontal ? box.offsetBy(dx: delta, dy: 0) : box.offsetBy(dx: 0, dy: delta)
        let g = (gap1 + gap2) / 2
        if horizontal {
            let y = moved.midY
            return (delta, [CGPoint(x: a.maxX, y: y), CGPoint(x: a.maxX + g, y: y), CGPoint(x: moved.maxX, y: y), CGPoint(x: moved.maxX + g, y: y)])
        } else {
            let x = moved.midX
            return (delta, [CGPoint(x: x, y: a.maxY), CGPoint(x: x, y: a.maxY + g), CGPoint(x: x, y: moved.maxY), CGPoint(x: x, y: moved.maxY + g)])
        }
    }

    // MARK: Snapping a point (creation, resize handles, connector ends)

    func snap(point p: CGPoint, against others: [CGRect]) -> SnapResult {
        var result = SnapResult()
        var bestX: (CGFloat, CGFloat)?
        var bestY: (CGFloat, CGFloat)?
        if snapToObjects {
            for r in others {
                for t in [r.minX, r.midX, r.maxX] where abs(t - p.x) <= tolerance && abs(t - p.x) < abs(bestX?.0 ?? .infinity) {
                    bestX = (t - p.x, t)
                }
                for t in [r.minY, r.midY, r.maxY] where abs(t - p.y) <= tolerance && abs(t - p.y) < abs(bestY?.0 ?? .infinity) {
                    bestY = (t - p.y, t)
                }
            }
        }
        if let g = gridSpacing, g > 0 {
            if bestX == nil { result.offset.x = (p.x / g).rounded() * g - p.x }
            if bestY == nil { result.offset.y = (p.y / g).rounded() * g - p.y }
        }
        let q = p + CGPoint(x: bestX?.0 ?? result.offset.x, y: bestY?.0 ?? result.offset.y)
        if let bx = bestX {
            result.offset.x = bx.0
            var lo = q.y, hi = q.y
            for r in others where [r.minX, r.midX, r.maxX].contains(where: { abs($0 - bx.1) < 0.01 }) { lo = min(lo, r.minY); hi = max(hi, r.maxY) }
            result.guides.append(.line(CGPoint(x: bx.1, y: lo), CGPoint(x: bx.1, y: hi)))
        }
        if let by = bestY {
            result.offset.y = by.0
            var lo = q.x, hi = q.x
            for r in others where [r.minY, r.midY, r.maxY].contains(where: { abs($0 - by.1) < 0.01 }) { lo = min(lo, r.minX); hi = max(hi, r.maxX) }
            result.guides.append(.line(CGPoint(x: lo, y: by.1), CGPoint(x: hi, y: by.1)))
        }
        return result
    }
}
