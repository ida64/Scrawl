import CoreGraphics
import Foundation

enum Handle: Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case rotation
    case lineStart, lineEnd

    static let resizeHandles: [Handle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }

    /// Normalized position on the box (0...1).
    var unit: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .top: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .right: return CGPoint(x: 1, y: 0.5)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        case .bottom: return CGPoint(x: 0.5, y: 1)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .left: return CGPoint(x: 0, y: 0.5)
        case .rotation, .lineStart, .lineEnd: return CGPoint(x: 0.5, y: 0.5)
        }
    }

    var movesX: Bool { self != .top && self != .bottom }
    var movesY: Bool { self != .left && self != .right }
}

enum TransformMath {
    /// Computes a new box when dragging `handle` of box `r0` to local point `p`.
    /// Returns a rect that may have negative width/height to signal flipping.
    static func resizedBox(_ r0: CGRect, handle: Handle, to p: CGPoint, keepAspect: Bool, fromCenter: Bool) -> CGRect {
        var minX = r0.minX, minY = r0.minY, maxX = r0.maxX, maxY = r0.maxY
        let u = handle.unit
        if handle.movesX { if u.x == 0 { minX = p.x } else { maxX = p.x } }
        if handle.movesY { if u.y == 0 { minY = p.y } else { maxY = p.y } }
        if fromCenter {
            let c = r0.center
            if handle.movesX {
                let half = u.x == 0 ? c.x - p.x : p.x - c.x
                minX = c.x - half; maxX = c.x + half
            }
            if handle.movesY {
                let half = u.y == 0 ? c.y - p.y : p.y - c.y
                minY = c.y - half; maxY = c.y + half
            }
        }
        var w = maxX - minX, h = maxY - minY
        if keepAspect, r0.width > 0, r0.height > 0 {
            let aspect = r0.width / r0.height
            if handle.isCorner {
                let sx = w / r0.width, sy = h / r0.height
                let s = abs(sx) > abs(sy) ? abs(sx) : abs(sy)
                w = s * r0.width * sign(of: sx)
                h = s * r0.height * sign(of: sy)
            } else if handle.movesX {
                h = abs(w) / aspect
            } else {
                w = abs(h) * aspect
            }
            // Re-anchor after aspect correction.
            if fromCenter {
                let c = r0.center
                return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
            }
            let ax: CGFloat, ay: CGFloat
            if handle.isCorner {
                ax = u.x == 0 ? r0.maxX : r0.minX
                ay = u.y == 0 ? r0.maxY : r0.minY
                return CGRect(x: u.x == 0 ? ax - w : ax, y: u.y == 0 ? ay - h : ay, width: w, height: h)
            } else if handle.movesX {
                ax = u.x == 0 ? r0.maxX : r0.minX
                return CGRect(x: u.x == 0 ? ax - w : ax, y: r0.midY - h / 2, width: w, height: h)
            } else {
                ay = u.y == 0 ? r0.maxY : r0.minY
                return CGRect(x: r0.midX - w / 2, y: u.y == 0 ? ay - h : ay, width: w, height: h)
            }
        }
        return CGRect(x: minX, y: minY, width: w, height: h)
    }

    private static func sign(of v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }

    /// Produces a standardized rect plus flip flags from a possibly-negative rect.
    static func standardize(_ r: CGRect) -> (CGRect, flipX: Bool, flipY: Bool) {
        let flipX = r.size.width < 0, flipY = r.size.height < 0
        var s = CGRect(x: flipX ? r.minX + r.width : r.minX, y: flipY ? r.minY + r.height : r.minY,
                       width: abs(r.width), height: abs(r.height))
        s.size.width = max(s.width, 1)
        s.size.height = max(s.height, 1)
        return (s, flipX, flipY)
    }

    /// Mirrors inner geometry of point-based elements.
    static func flip(_ e: inout Element, x: Bool, y: Bool) {
        guard x || y else { return }
        let w = e.frame.width, h = e.frame.height
        func f(_ p: CGPoint) -> CGPoint { CGPoint(x: x ? w - p.x : p.x, y: y ? h - p.y : p.y) }
        switch e.kind {
        case var .line(d):
            d.points = d.points.map(f)
            e.kind = .line(d)
        case var .arrow(d):
            d.points = d.points.map(f)
            e.kind = .arrow(d)
        case var .freehand(d):
            d.points = d.points.map(f)
            e.kind = .freehand(d)
        default:
            break
        }
    }

    // MARK: Single element

    /// Resizes one element (possibly rotated) by dragging a handle to a world point.
    static func resize(_ original: Element, handle: Handle, to world: CGPoint, keepAspect: Bool, fromCenter: Bool) -> Element {
        var e = original
        let c0 = original.center
        let local = world.rotated(around: c0, by: -original.rotation)
        var aspect = keepAspect
        // Images keep their aspect ratio on corner drags unless Shift is held.
        if case .image = original.kind { aspect = handle.isCorner ? !keepAspect : false }

        // Text: corners scale the font, sides change the wrap width.
        if case var .text(t) = original.kind {
            if handle.isCorner {
                let raw = resizedBox(original.frame, handle: handle, to: local, keepAspect: true, fromCenter: fromCenter)
                let (box, _, _) = standardize(raw)
                let scale = box.width / max(original.frame.width, 1)
                e.style.fontSize = max(4, (original.style.fontSize * Double(scale) * 2).rounded() / 2)
                if !t.autoWidth { e.frame.size.width = original.frame.width * scale }
                TextLayout.fit(&e)
                let anchorLocal = original.frame.point(atUnit: CGPoint(x: 1 - handle.unit.x, y: 1 - handle.unit.y))
                let newAnchorUnit = CGPoint(x: 1 - handle.unit.x, y: 1 - handle.unit.y)
                let newRect = CGRect(x: anchorLocal.x - e.frame.width * newAnchorUnit.x, y: anchorLocal.y - e.frame.height * newAnchorUnit.y,
                                     width: e.frame.width, height: e.frame.height)
                e.frame = place(newRect, unrotatedAround: c0, rotation: original.rotation)
                return e
            } else if handle.movesX {
                let raw = resizedBox(original.frame, handle: handle, to: local, keepAspect: false, fromCenter: fromCenter)
                let (box, _, _) = standardize(raw)
                t.autoWidth = false
                e.kind = .text(t)
                e.frame.size.width = max(box.width, CGFloat(original.style.fontSize))
                TextLayout.fit(&e)
                let newRect = CGRect(x: box.minX, y: original.frame.minY, width: e.frame.width, height: e.frame.height)
                e.frame = place(newRect, unrotatedAround: c0, rotation: original.rotation)
                return e
            }
            return original
        }

        let raw = resizedBox(original.frame, handle: handle, to: local, keepAspect: aspect, fromCenter: fromCenter)
        let (box, fx, fy) = standardize(raw)
        e.resize(to: CGRect(origin: original.frame.origin, size: box.size))
        flip(&e, x: fx, y: fy)
        e.frame = place(box, unrotatedAround: c0, rotation: original.rotation)
        return e
    }

    /// Converts a rect expressed in the unrotated space around `pivot` into the element frame
    /// whose rotation about its own center reproduces the same world placement.
    static func place(_ r: CGRect, unrotatedAround pivot: CGPoint, rotation: CGFloat) -> CGRect {
        guard rotation != 0 else { return r }
        let worldCenter = r.center.rotated(around: pivot, by: rotation)
        return CGRect(center: worldCenter, size: r.size)
    }

    // MARK: Image cropping

    /// The full (uncropped) image rect in the element's unrotated space.
    static func uncroppedRect(_ e: Element) -> CGRect? {
        guard case let .image(img) = e.kind, img.crop.width > 0, img.crop.height > 0 else { return nil }
        let c = img.crop, f = e.frame
        return CGRect(x: f.minX - c.minX / c.width * f.width, y: f.minY - c.minY / c.height * f.height,
                      width: f.width / c.width, height: f.height / c.height)
    }

    /// Dragging a handle in crop mode trims the visible region; the image content stays put.
    static func crop(_ original: Element, handle: Handle, to world: CGPoint) -> Element {
        guard case var .image(img) = original.kind, let full = uncroppedRect(original) else { return original }
        let local = world.rotated(around: original.center, by: -original.rotation)
        let (box, _, _) = standardize(resizedBox(original.frame, handle: handle, to: local, keepAspect: false, fromCenter: false))
        var r = box.intersection(full)
        guard !r.isNull else { return original }
        r.size.width = max(r.width, 4)
        r.size.height = max(r.height, 4)
        img.crop = CGRect(x: (r.minX - full.minX) / full.width, y: (r.minY - full.minY) / full.height,
                          width: r.width / full.width, height: r.height / full.height)
        var e = original
        e.kind = .image(img)
        e.frame = place(r, unrotatedAround: original.center, rotation: original.rotation)
        return e
    }

    // MARK: Multiple elements

    /// Scales a set of elements from box `b0` to box `b1` (b1 may be negative to flip).
    static func scale(_ originals: [Element], from b0: CGRect, to b1: CGRect, in scene: Scene) {
        let sx = b0.width > 0 ? b1.width / b0.width : 1
        let sy = b0.height > 0 ? b1.height / b0.height : 1
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: b1.minX + (p.x - b0.minX) * sx, y: b1.minY + (p.y - b0.minY) * sy)
        }
        scene.batch {
            for o in originals {
                var e = o
                switch o.kind {
                case .line, .arrow:
                    e.setLinearWorldPoints(o.worldPoints.map(map))
                case .text:
                    let s = min(abs(sx), abs(sy))
                    e.style.fontSize = max(2, o.style.fontSize * Double(s))
                    if case var .text(t) = e.kind, !t.autoWidth { e.frame.size.width = o.frame.width * s; t.autoWidth = false; e.kind = .text(t) }
                    TextLayout.fit(&e)
                    e.frame = CGRect(center: map(o.center), size: e.frame.size)
                default:
                    let newSize = CGSize(width: max(1, o.frame.width * abs(sx)), height: max(1, o.frame.height * abs(sy)))
                    e.resize(to: CGRect(origin: o.frame.origin, size: newSize))
                    flip(&e, x: sx < 0, y: sy < 0)
                    e.frame = CGRect(center: map(o.center), size: newSize)
                    if (sx < 0) != (sy < 0) && o.rotation != 0 { e.rotation = -o.rotation }
                }
                scene.replace(e)
            }
        }
    }

    // MARK: Rotation

    static func rotate(_ ids: Set<ElementID>, by angle: CGFloat, around pivot: CGPoint, in scene: Scene, originals: [ElementID: Element]) {
        scene.batch {
            for id in ids {
                guard let o = originals[id], !o.isFrame else { continue }
                var e = o
                if o.isLinear {
                    e.setLinearWorldPoints(o.worldPoints.map { $0.rotated(around: pivot, by: angle) })
                } else {
                    e.frame = CGRect(center: o.center.rotated(around: pivot, by: angle), size: o.frame.size)
                    e.rotation = Geometry.normalizeAngle(o.rotation + angle)
                }
                scene.replace(e)
            }
            BindingSolver.updateConnectors(in: scene, affectedBy: ids)
        }
    }
}
