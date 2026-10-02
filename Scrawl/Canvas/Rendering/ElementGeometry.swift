import CoreGraphics
import Foundation

/// Paths describing how an element is drawn, in element-local space (frame origin at 0,0;
/// rotation is applied by the renderer around the frame center).
struct RenderGeometry {
    /// Region filled with the fill color (also the clip region for hatch fills).
    var fillArea: CGPath?
    /// Hatch lines, stroked with the fill color and clipped to `fillArea`.
    var hatch: CGPath?
    /// Outline paths stroked with the stroke color.
    var stroke: CGPath?
    /// Solid areas filled with the stroke color (freehand bodies, solid arrowheads).
    var strokeFill: CGPath?
    /// Arrowhead strokes, never dashed.
    var heads: CGPath?
}

enum ElementGeometry {
    // MARK: Clean outlines (local space)

    static func localRect(_ e: Element) -> CGRect { CGRect(origin: .zero, size: e.frame.size) }

    static func clampedRadius(_ e: Element) -> CGFloat {
        var r = CGFloat(e.style.cornerRadius)
        // Soft mode rounds shapes generously even without an explicit radius.
        if e.style.renderStyle == .soft && (e.type == .rectangle || e.type == .diamond) {
            r = max(r, min(e.frame.width, e.frame.height) * 0.22)
        }
        return max(0, min(r, min(e.frame.width, e.frame.height) / 2))
    }

    /// The clean outline of closed shapes, or the centerline of open ones, in local space.
    static func outline(_ e: Element) -> CGPath {
        let r = localRect(e)
        switch e.kind {
        case .rectangle, .image, .frame, .text:
            let rad = e.type == .rectangle ? clampedRadius(e) : 0
            return rad > 0 ? CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) : CGPath(rect: r, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: r, transform: nil)
        case .diamond:
            return diamondPath(r, radius: clampedRadius(e))
        case let .line(d), let .arrow(d):
            return linearCenterline(d, routing: e.style.routing)
        case let .freehand(d):
            return PathSmoothing.smoothPath(through: d.points)
        }
    }

    static func diamondPath(_ r: CGRect, radius: CGFloat) -> CGPath {
        let pts = Geometry.diamondPoints(in: r)
        let p = CGMutablePath()
        guard radius > 0 else {
            p.addLines(between: pts)
            p.closeSubpath()
            return p
        }
        let start = pts[0].lerp(to: pts[1], 0.5)
        p.move(to: start)
        for i in 1...4 {
            p.addArc(tangent1End: pts[i % 4], tangent2End: pts[(i + 1) % 4], radius: radius * 0.6)
        }
        p.closeSubpath()
        return p
    }

    /// Points of the rendered route for a linear element (local space).
    static func route(_ d: LinearData, routing: LineRouting) -> [CGPoint] {
        guard d.points.count >= 2, routing == .elbow, let s = d.points.first, let e = d.points.last else { return d.points }
        func horizontal(_ b: ConnectorBinding?, fallback: Bool) -> Bool {
            guard let b else { return fallback }
            return abs(b.anchor.x - 0.5) >= abs(b.anchor.y - 0.5)
        }
        let dx = e.x - s.x, dy = e.y - s.y
        let sh = horizontal(d.startBinding, fallback: abs(dx) >= abs(dy))
        let eh = horizontal(d.endBinding, fallback: abs(dx) >= abs(dy))
        switch (sh, eh) {
        case (true, true):
            let mx = (s.x + e.x) / 2
            return [s, CGPoint(x: mx, y: s.y), CGPoint(x: mx, y: e.y), e]
        case (false, false):
            let my = (s.y + e.y) / 2
            return [s, CGPoint(x: s.x, y: my), CGPoint(x: e.x, y: my), e]
        case (true, false):
            return [s, CGPoint(x: e.x, y: s.y), e]
        case (false, true):
            return [s, CGPoint(x: s.x, y: e.y), e]
        }
    }

    static func linearCenterline(_ d: LinearData, routing: LineRouting) -> CGPath {
        let pts = route(d, routing: routing)
        if routing == .curved && pts.count > 2 { return PathSmoothing.smoothPath(through: pts) }
        if routing == .curved && pts.count == 2 {
            // A gentle arc for two-point curved connectors.
            let a = pts[0], b = pts[1]
            let mid = a.lerp(to: b, 0.5)
            let n = CGPoint(x: -(b.y - a.y), y: b.x - a.x) * 0.15
            let p = CGMutablePath()
            p.move(to: a)
            p.addQuadCurve(to: b, control: mid + n)
            return p
        }
        let p = CGMutablePath()
        if let f = pts.first { p.move(to: f); p.addLines(between: pts) }
        return p
    }

    // MARK: Render geometry

    static func build(_ e: Element) -> RenderGeometry {
        var g = RenderGeometry()
        var rng = SeededRandom(seed: e.seed)
        let sketch = e.style.renderStyle == .ink
        let passes = e.style.strokeStyle == .solid ? 2 : 1
        let rect = localRect(e)
        let sw = CGFloat(e.style.strokeWidth)

        switch e.kind {
        case .rectangle, .ellipse, .diamond:
            let clean = outline(e)
            g.fillArea = clean
            if sketch {
                switch e.kind {
                case .ellipse: g.stroke = SketchGenerator.roughEllipse(in: rect, rng: &rng, passes: passes)
                case .diamond where clampedRadius(e) == 0:
                    g.stroke = SketchGenerator.roughPolygon(Geometry.diamondPoints(in: rect), closed: true, rng: &rng, passes: passes)
                case .rectangle where clampedRadius(e) == 0:
                    g.stroke = SketchGenerator.roughPolygon(rect.corners, closed: true, rng: &rng, passes: passes)
                default:
                    g.stroke = SketchGenerator.roughOutline(clean, rng: &rng, passes: passes)
                }
            } else {
                g.stroke = clean
            }
            if e.style.fillStyle != .solid, !e.style.fillColor.isClear {
                let gap = max(6, sw * 3.5)
                let h = CGMutablePath()
                let angle: CGFloat = sketch ? -0.72 : -.pi / 4
                h.addPath(SketchGenerator.hachure(bounds: rect, angle: angle, gap: gap, rng: &rng, rough: sketch))
                if e.style.fillStyle == .crossHatch {
                    h.addPath(SketchGenerator.hachure(bounds: rect, angle: angle + .pi / 2, gap: gap, rng: &rng, rough: sketch))
                }
                g.hatch = h
            }

        case let .line(d), let .arrow(d):
            let pts = route(d, routing: e.style.routing)
            if sketch {
                if e.style.routing == .curved {
                    g.stroke = SketchGenerator.roughCurve(linearCenterline(d, routing: .curved), rng: &rng, passes: passes)
                } else {
                    g.stroke = SketchGenerator.roughPolyline(pts, rng: &rng, passes: passes)
                }
            } else {
                g.stroke = linearCenterline(d, routing: e.style.routing)
            }
            if case .arrow = e.kind {
                let heads = CGMutablePath()
                let solid = CGMutablePath()
                let centerline = linearCenterline(d, routing: e.style.routing).flattenedPolylines(tolerance: 0.5).first ?? pts
                if centerline.count >= 2 {
                    addHead(e.style.endArrowhead, tip: centerline[centerline.count - 1], from: tailPoint(centerline, reversed: false),
                            strokeWidth: sw, sketch: sketch, rng: &rng, stroke: heads, fill: solid)
                    addHead(e.style.startArrowhead, tip: centerline[0], from: tailPoint(centerline, reversed: true),
                            strokeWidth: sw, sketch: sketch, rng: &rng, stroke: heads, fill: solid)
                }
                g.heads = heads.isEmpty ? nil : heads
                g.strokeFill = solid.isEmpty ? nil : solid
            }

        case let .freehand(d):
            g.strokeFill = freehandBody(d, width: sw)

        case .frame:
            g.stroke = CGPath(roundedRect: rect, cornerWidth: 0, cornerHeight: 0, transform: nil)

        case .text, .image:
            break
        }
        return g
    }

    /// A point some distance back along the polyline from its end (or start when reversed),
    /// used to orient arrowheads on curves.
    private static func tailPoint(_ pts: [CGPoint], reversed: Bool) -> CGPoint {
        let seq = reversed ? pts : pts.reversed()
        guard let tip = seq.first else { return .zero }
        var prev = tip
        var dist: CGFloat = 0
        for p in seq.dropFirst() {
            dist += p.distance(to: prev)
            prev = p
            if dist >= 12 { return p }
        }
        return prev
    }

    static func headLength(strokeWidth sw: CGFloat) -> CGFloat { max(12, sw * 5) }

    private static func addHead(_ head: Arrowhead, tip: CGPoint, from: CGPoint, strokeWidth sw: CGFloat, sketch: Bool,
                                rng: inout SeededRandom, stroke: CGMutablePath, fill: CGMutablePath) {
        guard head != .none else { return }
        let dir = (tip - from).normalized
        guard dir.length > 0 else { return }
        let len = headLength(strokeWidth: sw)
        let normal = CGPoint(x: -dir.y, y: dir.x)
        let base = tip - dir * len
        let wing = len * 0.5
        let l = base + normal * wing, r = base - normal * wing
        switch head {
        case .none: break
        case .arrow:
            if sketch {
                SketchGenerator.addRoughLine(stroke, l, tip, rng: &rng, offset: 0.8)
                SketchGenerator.addRoughLine(stroke, tip, r, rng: &rng, offset: 0.8, move: false)
            } else {
                stroke.move(to: l); stroke.addLine(to: tip); stroke.addLine(to: r)
            }
        case .triangle:
            fill.move(to: tip); fill.addLine(to: l); fill.addLine(to: r); fill.closeSubpath()
            stroke.move(to: tip); stroke.addLine(to: l); stroke.addLine(to: r); stroke.closeSubpath()
        case .dot:
            let rad = max(3, sw * 1.8)
            fill.addEllipse(in: CGRect(center: tip, size: CGSize(width: rad * 2, height: rad * 2)))
        case .bar:
            let w = len * 0.55
            stroke.move(to: tip + normal * w); stroke.addLine(to: tip - normal * w)
        }
    }

    /// Variable-width freehand body: a single closed outline around the smoothed centerline.
    static func freehandBody(_ d: FreehandData, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard !d.points.isEmpty else { return path }
        let baseRadius = max(0.75, width * 0.9)
        let pts = d.points
        func pressure(_ i: Int) -> CGFloat {
            guard i < d.pressures.count else { return 0.6 }
            return CGFloat(max(0, min(1, d.pressures[i])))
        }
        // Resample densely with interpolated pressure for a smooth outline.
        let smoothPolyline = PathSmoothing.smoothPath(through: pts).flattenedPolylines(tolerance: 0.5).first ?? pts
        let spacing = max(0.75, baseRadius * 0.6)
        let samples = SketchGenerator.resample(smoothPolyline, spacing: spacing)
        guard samples.count > 1 else {
            let r = baseRadius * (0.4 + 0.6 * pressure(0))
            path.addEllipse(in: CGRect(center: pts[0], size: CGSize(width: r * 2, height: r * 2)))
            return path
        }
        let n = samples.count
        var radii = [CGFloat](repeating: baseRadius, count: n)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let src = t * CGFloat(max(0, pts.count - 1))
            let i0 = Int(src.rounded(.down)), i1 = min(pts.count - 1, i0 + 1)
            let f = src - CGFloat(i0)
            let pr = pressure(i0) * (1 - f) + pressure(i1) * f
            // Gentle taper at the very ends.
            let edge = min(CGFloat(i), CGFloat(n - 1 - i))
            let taper = min(1, 0.45 + edge / 6)
            radii[i] = baseRadius * (0.35 + 0.65 * pr) * taper
        }
        // Tangents and normals per sample.
        var normals = [CGPoint](repeating: .zero, count: n)
        for i in 0..<n {
            let a = samples[max(0, i - 1)], b = samples[min(n - 1, i + 1)]
            let d = (b - a).normalized
            normals[i] = d.length > 0 ? CGPoint(x: -d.y, y: d.x) : (i > 0 ? normals[i - 1] : CGPoint(x: 0, y: 1))
        }
        let left = (0..<n).map { samples[$0] + normals[$0] * radii[$0] }
        let right = (0..<n).map { samples[$0] - normals[$0] * radii[$0] }
        // One closed outline: left edge forward, round end cap, right edge back, round start cap.
        // Non-zero winding keeps self-overlapping strokes solid.
        func cap(_ center: CGPoint, from nrm: CGPoint, dir: CGPoint, r: CGFloat) {
            let steps = 8
            for k in 1..<steps {
                let t = CGFloat.pi * CGFloat(k) / CGFloat(steps)
                path.addLine(to: center + (nrm * cos(t) + dir * sin(t)) * r)
            }
        }
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        let endDir = CGPoint(x: normals[n - 1].y, y: -normals[n - 1].x)
        cap(samples[n - 1], from: normals[n - 1], dir: endDir, r: radii[n - 1])
        for p in right.reversed() { path.addLine(to: p) }
        let startDir = CGPoint(x: -normals[0].y, y: normals[0].x)
        cap(samples[0], from: -normals[0], dir: startDir, r: radii[0])
        path.closeSubpath()
        return path
    }
}
