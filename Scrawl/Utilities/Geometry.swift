import CoreGraphics
import Foundation

// MARK: - Point arithmetic

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    static func / (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x / s, y: a.y / s) }
    static prefix func - (a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: -a.y) }
    static func += (a: inout CGPoint, b: CGPoint) { a = a + b }
    static func -= (a: inout CGPoint, b: CGPoint) { a = a - b }

    var length: CGFloat { hypot(x, y) }

    func distance(to p: CGPoint) -> CGFloat { hypot(p.x - x, p.y - y) }

    var normalized: CGPoint {
        let l = length
        return l > 0 ? self / l : .zero
    }

    func dot(_ p: CGPoint) -> CGFloat { x * p.x + y * p.y }
    func cross(_ p: CGPoint) -> CGFloat { x * p.y - y * p.x }

    /// Rotates the point around `pivot` by `angle` radians (positive = clockwise in a y-down space).
    func rotated(around pivot: CGPoint, by angle: CGFloat) -> CGPoint {
        guard angle != 0 else { return self }
        let c = cos(angle), s = sin(angle)
        let dx = x - pivot.x, dy = y - pivot.y
        return CGPoint(x: pivot.x + dx * c - dy * s, y: pivot.y + dx * s + dy * c)
    }

    func lerp(to p: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: x + (p.x - x) * t, y: y + (p.y - y) * t)
    }

    var isFinite: Bool { x.isFinite && y.isFinite }
}

extension CGSize {
    static func * (a: CGSize, s: CGFloat) -> CGSize { CGSize(width: a.width * s, height: a.height * s) }
}

// MARK: - Rect helpers

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Rect spanning two arbitrary corner points.
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }

    /// Corners after rotating the rect around its center.
    func rotatedCorners(_ angle: CGFloat) -> [CGPoint] {
        let c = center
        return corners.map { $0.rotated(around: c, by: angle) }
    }

    /// Axis-aligned bounds of this rect rotated around its center.
    func rotatedBounds(_ angle: CGFloat) -> CGRect {
        guard angle != 0 else { return self }
        return CGRect.bounding(rotatedCorners(angle)) ?? self
    }

    static func bounding<S: Sequence>(_ points: S) -> CGRect? where S.Element == CGPoint {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var any = false
        for p in points {
            any = true
            minX = Swift.min(minX, p.x); minY = Swift.min(minY, p.y)
            maxX = Swift.max(maxX, p.x); maxY = Swift.max(maxY, p.y)
        }
        guard any else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func union<S: Sequence>(_ rects: S) -> CGRect? where S.Element == CGRect {
        var result: CGRect?
        for r in rects { result = result.map { $0.union(r) } ?? r }
        return result
    }

    /// Like `insetBy` with negative values, but safe for empty rects.
    func expanded(by d: CGFloat) -> CGRect {
        CGRect(x: minX - d, y: minY - d, width: width + 2 * d, height: height + 2 * d)
    }

    /// Point at a normalized (0...1) location inside the rect.
    func point(atUnit u: CGPoint) -> CGPoint {
        CGPoint(x: minX + width * u.x, y: minY + height * u.y)
    }

    func unitPoint(of p: CGPoint) -> CGPoint {
        CGPoint(x: width > 0 ? (p.x - minX) / width : 0.5, y: height > 0 ? (p.y - minY) / height : 0.5)
    }

    var isFiniteRect: Bool { origin.isFinite && size.width.isFinite && size.height.isFinite }
}

// MARK: - Geometry algorithms

enum Geometry {
    /// Shortest distance from `p` to segment `ab`.
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let len2 = ab.dot(ab)
        guard len2 > 0 else { return p.distance(to: a) }
        let t = max(0, min(1, (p - a).dot(ab) / len2))
        return p.distance(to: a + ab * t)
    }

    static func distance(from p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        guard pts.count > 1 else { return p.distance(to: first) }
        var best = CGFloat.infinity
        for i in 1..<pts.count {
            best = min(best, distance(from: p, toSegment: pts[i - 1], pts[i]))
        }
        return best
    }

    /// Even-odd point-in-polygon test.
    static func polygon(_ poly: [CGPoint], contains p: CGPoint) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Intersection point of segments p1p2 and p3p4, if any.
    static func segmentIntersection(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> CGPoint? {
        let r = p2 - p1, s = p4 - p3
        let denom = r.cross(s)
        guard abs(denom) > 1e-12 else { return nil }
        let t = (p3 - p1).cross(s) / denom
        let u = (p3 - p1).cross(r) / denom
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return p1 + r * t
    }

    /// Snaps an angle (radians) to the nearest multiple of `step`.
    static func snapAngle(_ angle: CGFloat, step: CGFloat = .pi / 12) -> CGFloat {
        (angle / step).rounded() * step
    }

    /// Snaps the vector from `origin` to `p` to the nearest `step` angle while keeping its length.
    static func snapPoint(_ p: CGPoint, from origin: CGPoint, step: CGFloat = .pi / 12) -> CGPoint {
        let d = p - origin
        let len = d.length
        let a = snapAngle(atan2(d.y, d.x), step: step)
        return origin + CGPoint(x: cos(a) * len, y: sin(a) * len)
    }

    /// Normalizes an angle into (-π, π].
    static func normalizeAngle(_ a: CGFloat) -> CGFloat {
        var r = a.truncatingRemainder(dividingBy: 2 * .pi)
        if r <= -.pi { r += 2 * .pi }
        if r > .pi { r -= 2 * .pi }
        return r
    }

    /// Points of a regular diamond inscribed in `rect`.
    static func diamondPoints(in rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    /// Point on an ellipse boundary (axis-aligned, inscribed in rect) along the ray from center toward `p`.
    static func ellipseBoundaryPoint(in rect: CGRect, toward p: CGPoint) -> CGPoint {
        let c = rect.center
        let d = p - c
        let a = rect.width / 2, b = rect.height / 2
        guard a > 0, b > 0, d.length > 0 else { return c }
        let t = 1 / sqrt((d.x * d.x) / (a * a) + (d.y * d.y) / (b * b))
        return c + d * t
    }
}

// MARK: - Path flattening

extension CGPath {
    /// Approximates the path as a list of polylines (one per subpath).
    func flattenedPolylines(tolerance: CGFloat = 1) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var last = CGPoint.zero
        var start = CGPoint.zero
        let steps = max(4, Int(16 / max(tolerance, 0.25)))
        applyWithBlock { elementPtr in
            let e = elementPtr.pointee
            switch e.type {
            case .moveToPoint:
                if current.count > 1 { result.append(current) }
                last = e.points[0]; start = last
                current = [last]
            case .addLineToPoint:
                last = e.points[0]
                current.append(last)
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), mt = 1 - t
                    current.append(CGPoint(x: mt * mt * last.x + 2 * mt * t * c.x + t * t * p.x,
                                           y: mt * mt * last.y + 2 * mt * t * c.y + t * t * p.y))
                }
                last = p
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], p = e.points[2]
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), mt = 1 - t
                    let a = mt * mt * mt, b = 3 * mt * mt * t, cc = 3 * mt * t * t, d = t * t * t
                    current.append(CGPoint(x: a * last.x + b * c1.x + cc * c2.x + d * p.x,
                                           y: a * last.y + b * c1.y + cc * c2.y + d * p.y))
                }
                last = p
            case .closeSubpath:
                current.append(start)
                last = start
            @unknown default:
                break
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }
}
