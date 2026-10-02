import CoreGraphics
import Foundation

/// Deterministic hand-drawn path generation (in the spirit of rough.js). Every function takes a
/// `SeededRandom` derived from the element seed, so output is stable across frames and exports.
enum SketchGenerator {
    static let maxOffset: CGFloat = 2

    /// Adds a single wobbly stroke from a to b.
    static func addRoughLine(_ path: CGMutablePath, _ a: CGPoint, _ b: CGPoint, rng: inout SeededRandom,
                             offset baseOffset: CGFloat = maxOffset, move: Bool = true, overlay: Bool = false) {
        let len = a.distance(to: b)
        var offset = baseOffset
        if offset * 10 > len { offset = len / 10 }
        // First pass wobbles by the full offset, the overlay pass by half (as rough.js does).
        let half = overlay ? offset / 2 : offset
        let diverge = 0.2 + CGFloat(rng.next()) * 0.2
        // Bowing pushes the midpoint perpendicular to the segment, which gives the drawn feel.
        var midX = (b.y - a.y) / 200 * baseOffset
        var midY = (a.x - b.x) / 200 * baseOffset
        midX += CGFloat(rng.signed()) * half
        midY += CGFloat(rng.signed()) * half
        func j(_ o: CGFloat) -> CGFloat { CGFloat(rng.signed()) * o }
        let start = CGPoint(x: a.x + j(half), y: a.y + j(half))
        if move { path.move(to: start) } else { path.addLine(to: start) }
        let c1 = CGPoint(x: midX + a.x + (b.x - a.x) * diverge + j(half), y: midY + a.y + (b.y - a.y) * diverge + j(half))
        let c2 = CGPoint(x: midX + a.x + 2 * (b.x - a.x) * diverge + j(half), y: midY + a.y + 2 * (b.y - a.y) * diverge + j(half))
        let end = CGPoint(x: b.x + j(half), y: b.y + j(half))
        path.addCurve(to: end, control1: c1, control2: c2)
    }

    /// Two overlaid rough strokes, as a hand would when tracing a line twice.
    static func roughLine(_ a: CGPoint, _ b: CGPoint, rng: inout SeededRandom, into path: CGMutablePath, passes: Int = 2) {
        for pass in 0..<passes {
            addRoughLine(path, a, b, rng: &rng, offset: maxOffset, overlay: pass > 0)
        }
    }

    static func roughPolygon(_ pts: [CGPoint], closed: Bool, rng: inout SeededRandom, passes: Int = 2) -> CGPath {
        let path = CGMutablePath()
        guard pts.count > 1 else { return path }
        let n = closed ? pts.count : pts.count - 1
        for i in 0..<n {
            roughLine(pts[i], pts[(i + 1) % pts.count], rng: &rng, into: path, passes: passes)
        }
        return path
    }

    static func roughEllipse(in rect: CGRect, rng: inout SeededRandom, passes: Int = 2) -> CGPath {
        let path = CGMutablePath()
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0.5, ry > 0.5 else { return CGPath(ellipseIn: rect, transform: nil) }
        let c = rect.center
        let perimeter = 2 * CGFloat.pi * sqrt((rx * rx + ry * ry) / 2)
        let count = max(8, min(36, Int(perimeter / 24)))
        let inc = 2 * CGFloat.pi / CGFloat(count)
        for pass in 0..<passes {
            let jitter = min(rx, ry) * 0.04 * (pass == 0 ? 1 : 1.5) + 0.6
            let start = CGFloat(rng.next()) * 2 * .pi
            var pts: [CGPoint] = []
            // Overshoot slightly past the start point for the classic loose-closure look.
            let overlap = inc * CGFloat(0.4 + rng.next() * 0.4)
            var a = start
            while a < start + 2 * .pi + overlap {
                let r = 1 + CGFloat(rng.signed()) * 0.025
                pts.append(CGPoint(x: c.x + rx * r * cos(a) + CGFloat(rng.signed()) * jitter,
                                   y: c.y + ry * r * sin(a) + CGFloat(rng.signed()) * jitter))
                a += inc
            }
            path.addPath(PathSmoothing.smoothPath(through: pts, closed: false, tension: 0.9))
        }
        return path
    }

    /// Roughens an arbitrary closed outline by resampling and jittering it.
    static func roughOutline(_ outline: CGPath, rng: inout SeededRandom, passes: Int = 2) -> CGPath {
        let path = CGMutablePath()
        for poly in outline.flattenedPolylines(tolerance: 2) {
            let resampled = resample(poly, spacing: 18)
            for pass in 0..<passes {
                let jitter: CGFloat = pass == 0 ? 0.9 : 1.4
                var pts = resampled.map { $0 + CGPoint(x: CGFloat(rng.signed()) * jitter, y: CGFloat(rng.signed()) * jitter) }
                if let f = pts.first { pts.append(f + CGPoint(x: CGFloat(rng.signed()) * 2, y: CGFloat(rng.signed()) * 2)) }
                path.addPath(PathSmoothing.smoothPath(through: pts, closed: false, tension: 0.7))
            }
        }
        return path
    }

    /// Roughens an open polyline, preserving sharp corners.
    static func roughPolyline(_ pts: [CGPoint], rng: inout SeededRandom, passes: Int = 2) -> CGPath {
        roughPolygon(pts, closed: false, rng: &rng, passes: passes)
    }

    /// Roughens a smooth open curve by jittering resampled points.
    static func roughCurve(_ curve: CGPath, rng: inout SeededRandom, passes: Int = 2) -> CGPath {
        let path = CGMutablePath()
        for poly in curve.flattenedPolylines(tolerance: 1) {
            let resampled = resample(poly, spacing: 20)
            for pass in 0..<passes {
                let jitter: CGFloat = pass == 0 ? 0.8 : 1.3
                let pts = resampled.enumerated().map { i, p in
                    (i == 0 || i == resampled.count - 1) ? p : p + CGPoint(x: CGFloat(rng.signed()) * jitter, y: CGFloat(rng.signed()) * jitter)
                }
                path.addPath(PathSmoothing.smoothPath(through: pts, closed: false))
            }
        }
        return path
    }

    /// Parallel hatch lines covering `bounds`, to be clipped to the fill area.
    static func hachure(bounds: CGRect, angle: CGFloat, gap: CGFloat, rng: inout SeededRandom, rough: Bool) -> CGPath {
        let path = CGMutablePath()
        guard bounds.width > 0, bounds.height > 0, gap > 0 else { return path }
        let c = bounds.center
        let diag = hypot(bounds.width, bounds.height) / 2 + gap
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: -dir.y, y: dir.x)
        var t = -diag
        let maxLines = 2000
        var count = 0
        while t <= diag && count < maxLines {
            let mid = c + normal * t
            let a = mid - dir * diag, b = mid + dir * diag
            if rough { addRoughLine(path, a, b, rng: &rng, offset: 1.2) } else { path.move(to: a); path.addLine(to: b) }
            t += gap
            count += 1
        }
        return path
    }

    /// Resamples a polyline to roughly even spacing, keeping its first and last points.
    static func resample(_ poly: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard poly.count > 1 else { return poly }
        var total: CGFloat = 0
        for i in 1..<poly.count { total += poly[i].distance(to: poly[i - 1]) }
        let n = max(2, Int((total / spacing).rounded()))
        let step = total / CGFloat(n)
        var out: [CGPoint] = [poly[0]]
        var acc: CGFloat = 0
        var target = step
        for i in 1..<poly.count {
            let a = poly[i - 1], b = poly[i]
            let seg = a.distance(to: b)
            while seg > 0 && acc + seg >= target && out.count < n {
                out.append(a.lerp(to: b, (target - acc) / seg))
                target += step
            }
            acc += seg
        }
        if let last = poly.last, out.last != last { out.append(last) }
        return out
    }
}
