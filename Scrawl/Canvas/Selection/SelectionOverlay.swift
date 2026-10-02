import AppKit

/// Screen-space geometry of the selection chrome. Handles stay a constant size at every zoom.
struct SelectionOverlay {
    static let handleSize: CGFloat = 7
    static let rotationOffset: CGFloat = 16
    static let hitSlop: CGFloat = 5

    enum Kind {
        case none
        /// Single box-like element (possibly rotated) or a multi-selection AABB.
        case box(world: CGRect, rotation: CGFloat, handles: [(Handle, CGPoint)], locked: Bool)
        /// Single line or arrow: endpoint handles only.
        case linear(points: [CGPoint], handles: [(Handle, CGPoint)], locked: Bool)
    }

    let kind: Kind
    /// Outlines of each selected element (screen space) when more than one is selected.
    let memberOutlines: [[CGPoint]]

    init(editor: Editor) {
        let v = editor.viewport
        let els = editor.selectedElements
        guard !els.isEmpty else { kind = .none; memberOutlines = []; return }
        let locked = els.allSatisfy(\.isLocked)
        if els.count == 1, let e = els.first {
            memberOutlines = []
            if e.isLinear {
                let pts = e.worldPoints.map(v.toScreen)
                var hs: [(Handle, CGPoint)] = []
                if !locked, let f = pts.first, let l = pts.last { hs = [(.lineStart, f), (.lineEnd, l)] }
                kind = .linear(points: pts, handles: hs, locked: locked)
                return
            }
            kind = .box(world: e.frame, rotation: e.rotation,
                        handles: locked ? [] : SelectionOverlay.handles(for: e.frame, rotation: e.rotation, viewport: v, allowRotation: !e.isFrame, textMode: e.isText),
                        locked: locked)
            return
        }
        memberOutlines = els.map { e in e.frame.rotatedCorners(e.rotation).map(v.toScreen) }
        let box = CGRect.union(els.map(\.bounds)) ?? .zero
        let allowRotation = !els.contains(where: \.isFrame)
        kind = .box(world: box, rotation: 0,
                    handles: locked ? [] : SelectionOverlay.handles(for: box, rotation: 0, viewport: v, allowRotation: allowRotation, textMode: false),
                    locked: locked)
    }

    static func handles(for frame: CGRect, rotation: CGFloat, viewport v: CanvasViewport, allowRotation: Bool, textMode: Bool) -> [(Handle, CGPoint)] {
        let c = frame.center
        let screenW = frame.width * v.zoom, screenH = frame.height * v.zoom
        var list: [Handle] = textMode ? [.topLeft, .topRight, .bottomRight, .bottomLeft, .left, .right] : Handle.resizeHandles
        // Hide side handles on tiny boxes so corners stay grabbable.
        if screenW < 28 { list.removeAll { $0 == .top || $0 == .bottom } }
        if screenH < 28 { list.removeAll { $0 == .left || $0 == .right } }
        var out: [(Handle, CGPoint)] = list.map { h in
            (h, v.toScreen(frame.point(atUnit: h.unit).rotated(around: c, by: rotation)))
        }
        if allowRotation {
            // Scrawl's rotation ring sits just off the top-right corner, along the diagonal.
            let corner = v.toScreen(CGPoint(x: frame.maxX, y: frame.minY).rotated(around: c, by: rotation))
            let diag = CGPoint(x: 1, y: -1).normalized.rotated(around: .zero, by: rotation)
            out.append((.rotation, corner + diag * rotationOffset))
        }
        return out
    }

    var handles: [(Handle, CGPoint)] {
        switch kind {
        case .none: return []
        case let .box(_, _, h, _): return h
        case let .linear(_, h, _): return h
        }
    }

    /// The handle under a screen point, if any (rotation handle has a slightly bigger target).
    func handle(at screen: CGPoint) -> Handle? {
        for (h, p) in handles.reversed() {
            let r = h == .rotation ? 9 : SelectionOverlay.handleSize / 2 + SelectionOverlay.hitSlop
            if abs(screen.x - p.x) <= r && abs(screen.y - p.y) <= r { return h }
        }
        return nil
    }

    // MARK: Drawing

    func draw(in ctx: CGContext, viewport v: CanvasViewport, accent: CGColor, dark: Bool) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let faint = accent.copy(alpha: 0.35) ?? accent
        ctx.setLineWidth(1)
        for outline in memberOutlines {
            ctx.addLines(between: outline)
            ctx.closePath()
        }
        ctx.setStrokeColor(faint)
        ctx.strokePath()

        switch kind {
        case .none:
            return
        case let .box(world, rotation, handles, locked):
            let corners = world.rotatedCorners(rotation).map(v.toScreen)
            if !memberOutlines.isEmpty {
                // Multi-selection: a faint wash over the shared bounds.
                ctx.addLines(between: corners)
                ctx.closePath()
                ctx.setFillColor(accent.copy(alpha: 0.045) ?? accent)
                ctx.fillPath()
            }
            ctx.addLines(between: corners)
            ctx.closePath()
            ctx.setStrokeColor(accent.copy(alpha: 0.9) ?? accent)
            if locked { ctx.setLineDash(phase: 0, lengths: [3, 3]) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            drawHandles(handles, rotation: rotation, ctx: ctx, accent: accent, dark: dark)
            if locked, let tl = corners.first { drawLockBadge(at: tl, ctx: ctx, accent: accent) }
        case let .linear(points, handles, locked):
            if locked, let f = points.first { drawLockBadge(at: f, ctx: ctx, accent: accent) }
            drawHandles(handles, rotation: 0, ctx: ctx, accent: accent, dark: dark)
        }
    }

    private func drawHandles(_ handles: [(Handle, CGPoint)], rotation: CGFloat, ctx: CGContext, accent: CGColor, dark: Bool) {
        let s = SelectionOverlay.handleSize
        let face = CGColor(gray: dark ? 0.15 : 1, alpha: 1)
        ctx.setLineWidth(1.25)
        for (h, p) in handles {
            ctx.setFillColor(face)
            ctx.setStrokeColor(accent)
            switch h {
            case .rotation:
                // A small hollow ring.
                let r = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
                ctx.setFillColor(accent.copy(alpha: 0.15) ?? accent)
                ctx.fillEllipse(in: r)
                ctx.strokeEllipse(in: r)
            case .top, .bottom, .left, .right:
                // Edge handles are short pills aligned with their edge.
                let horizontal = (h == .top || h == .bottom)
                let size = horizontal ? CGSize(width: 12, height: 4.5) : CGSize(width: 4.5, height: 12)
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                ctx.rotate(by: rotation)
                let r = CGRect(center: .zero, size: size)
                let path = CGPath(roundedRect: r, cornerWidth: 2.25, cornerHeight: 2.25, transform: nil)
                ctx.addPath(path); ctx.fillPath()
                ctx.addPath(path); ctx.strokePath()
                ctx.restoreGState()
            default:
                let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
                ctx.fillEllipse(in: r)
                ctx.strokeEllipse(in: r)
            }
        }
    }

    private func drawLockBadge(at p: CGPoint, ctx: CGContext, accent: CGColor) {
        guard let img = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked") else { return }
        let r = CGRect(x: p.x - 7, y: p.y - 19, width: 14, height: 14)
        ctx.setFillColor(accent)
        ctx.fillEllipse(in: r.insetBy(dx: -2, dy: -2))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let tinted = img.withSymbolConfiguration(.init(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.white])))
        tinted?.draw(in: r.insetBy(dx: 3, dy: 3))
        NSGraphicsContext.restoreGraphicsState()
    }
}
