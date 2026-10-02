import CoreGraphics
import Foundation

/// Keeps connector endpoints attached to the shapes they're bound to.
enum BindingSolver {
    static let gap: CGFloat = 5

    /// World-space outline polylines of a bindable element.
    static func worldOutline(_ e: Element) -> [[CGPoint]] {
        let o = e.frame.origin
        return ElementGeometry.outline(e).flattenedPolylines(tolerance: 1).map { poly in
            poly.map { e.toWorld($0 + o) }
        }
    }

    static func anchorPoint(_ b: ConnectorBinding, target: Element) -> CGPoint {
        target.toWorld(target.frame.point(atUnit: b.anchor))
    }

    /// Where a connector endpoint bound to `target` should sit, approaching from `from`.
    static func endpoint(binding b: ConnectorBinding, target: Element, from: CGPoint, elbow: Bool, gap: CGFloat = gap) -> CGPoint {
        let anchor = anchorPoint(b, target: target)
        var approach = from
        if elbow {
            // Elbow connectors leave perpendicular to the side nearest the anchor.
            let u = b.anchor
            let horizontal = abs(u.x - 0.5) >= abs(u.y - 0.5)
            var dir = horizontal ? CGPoint(x: u.x >= 0.5 ? 1 : -1, y: 0) : CGPoint(x: 0, y: u.y >= 0.5 ? 1 : -1)
            dir = dir.rotated(around: .zero, by: target.rotation)
            approach = anchor + dir * (max(target.frame.width, target.frame.height) + 100)
        }
        guard approach.distance(to: anchor) > 0.5 else { return anchor }
        var best: CGPoint?
        var bestD = CGFloat.infinity
        for poly in worldOutline(target) where poly.count > 1 {
            for i in 1..<poly.count {
                if let p = Geometry.segmentIntersection(approach, anchor, poly[i - 1], poly[i]) {
                    let d = p.distance(to: approach)
                    if d < bestD { bestD = d; best = p }
                }
            }
        }
        guard let hit = best else { return anchor }
        let dir = (approach - hit).normalized
        return hit + dir * gap
    }

    /// Recomputes the bound endpoints of one linear element from the current scene.
    static func solve(_ e: Element, lookup: (ElementID) -> Element?) -> Element? {
        guard let d = e.linear, d.startBinding != nil || d.endBinding != nil, d.points.count >= 2 else { return nil }
        var pts = e.worldPoints
        let elbow = e.style.routing == .elbow
        let startTarget = d.startBinding.flatMap { lookup($0.elementID) }
        let endTarget = d.endBinding.flatMap { lookup($0.elementID) }
        let rawStart = both(d.startBinding, startTarget).map { anchorPoint($0.0, target: $0.1) } ?? pts[0]
        let rawEnd = both(d.endBinding, endTarget).map { anchorPoint($0.0, target: $0.1) } ?? pts[pts.count - 1]
        if let b = d.startBinding, let t = startTarget {
            let from = pts.count > 2 ? pts[1] : rawEnd
            pts[0] = endpoint(binding: b, target: t, from: from, elbow: elbow)
        }
        if let b = d.endBinding, let t = endTarget {
            let from = pts.count > 2 ? pts[pts.count - 2] : rawStart
            pts[pts.count - 1] = endpoint(binding: b, target: t, from: from, elbow: elbow)
        }
        var out = e
        out.setLinearWorldPoints(pts)
        return out == e ? nil : out
    }

    /// Updates every connector attached to any of `changed` (or that is itself in `changed`).
    static func updateConnectors(in scene: Scene, affectedBy changed: Set<ElementID>) {
        guard !changed.isEmpty else { return }
        scene.batch {
            for e in scene.elements where e.isLinear {
                guard let d = e.linear else { continue }
                let touches = changed.contains(e.id)
                    || d.startBinding.map { changed.contains($0.elementID) } == true
                    || d.endBinding.map { changed.contains($0.elementID) } == true
                guard touches, let solved = solve(e, lookup: scene.element) else { continue }
                scene.replace(solved)
            }
        }
    }

    /// Drops bindings that point at elements in `removed`.
    static func detach(from removed: Set<ElementID>, in scene: Scene) {
        scene.batch {
            for e in scene.elements where e.isLinear {
                guard var d = e.linear else { continue }
                var changed = false
                if let b = d.startBinding, removed.contains(b.elementID) { d.startBinding = nil; changed = true }
                if let b = d.endBinding, removed.contains(b.elementID) { d.endBinding = nil; changed = true }
                if changed { scene.update(e.id) { $0.linear = d } }
            }
        }
    }

    /// The bindable element near `world` (topmost first), with the anchor for a binding.
    static func target(at world: CGPoint, in scene: Scene, candidates: [Element], excluding: Set<ElementID>,
                       tolerance: CGFloat) -> (Element, CGPoint)? {
        for e in candidates.reversed() where e.isBindable && !e.isHidden && !excluding.contains(e.id) {
            let local = e.toLocal(world)
            let expanded = e.frame.expanded(by: tolerance)
            guard expanded.contains(local) else { continue }
            if HitTester.hits(e, world, tolerance: tolerance, selected: true) {
                var u = e.frame.unitPoint(of: local)
                u.x = max(0, min(1, u.x)); u.y = max(0, min(1, u.y))
                return (e, u)
            }
        }
        return nil
    }
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
