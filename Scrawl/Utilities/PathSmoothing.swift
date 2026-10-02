import CoreGraphics

enum PathSmoothing {
    /// Ramer–Douglas–Peucker simplification. Returns the indices kept so that parallel arrays
    /// (such as pressures) can be filtered consistently.
    static func simplifyIndices(_ pts: [CGPoint], epsilon: CGFloat) -> [Int] {
        guard pts.count > 2 else { return Array(pts.indices) }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var maxD: CGFloat = 0
            var idx = s
            for i in (s + 1)..<e {
                let d = Geometry.distance(from: pts[i], toSegment: pts[s], pts[e])
                if d > maxD { maxD = d; idx = i }
            }
            if maxD > epsilon {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return keep.indices.filter { keep[$0] }
    }

    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        simplifyIndices(pts, epsilon: epsilon).map { pts[$0] }
    }

    /// Builds a smooth path through the points using centripetal-ish Catmull-Rom → cubic Bézier conversion.
    static func smoothPath(through pts: [CGPoint], closed: Bool = false, tension: CGFloat = 0.5) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            if pts.count == 2 { path.addLine(to: pts[1]) }
            if closed { path.closeSubpath() }
            return path
        }
        let n = pts.count
        let k = tension / 3 * 2
        func p(_ i: Int) -> CGPoint {
            if closed { return pts[(i % n + n) % n] }
            return pts[max(0, min(n - 1, i))]
        }
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let p0 = p(i - 1), p1 = p(i), p2 = p(i + 1), p3 = p(i + 2)
            let c1 = p1 + (p2 - p0) * (k / 2)
            let c2 = p2 - (p3 - p1) * (k / 2)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }

    /// Moving-average smoothing that keeps endpoints fixed.
    static func relax(_ pts: [CGPoint], iterations: Int = 1) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var cur = pts
        for _ in 0..<iterations {
            var next = cur
            for i in 1..<(cur.count - 1) {
                next[i] = (cur[i - 1] + cur[i] * 2 + cur[i + 1]) / 4
            }
            cur = next
        }
        return cur
    }
}
