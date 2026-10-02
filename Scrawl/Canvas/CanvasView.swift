import AppKit
import UniformTypeIdentifiers

/// The infinite canvas. A single centralized Core Graphics renderer draws only visible elements
/// (culled through a spatial index), with all chrome drawn as a separate screen-space overlay.
final class CanvasView: NSView, NSMenuItemValidation {
    let editor: Editor
    let spatialIndex = SpatialIndex()
    let geometryCache = GeometryCache()
    private(set) lazy var interaction = InteractionController(canvas: self)
    private(set) var isSpaceHeld = false
    private var hoverID: ElementID?
    private var trackingArea: NSTrackingArea?
    private var observerToken: UUID?
    private var textEditor: TextEditorOverlay?
    private var frameRenamer: NSTextField?
    private var didInitialFit = false

    /// Last frame's render time, for the debug HUD and benchmarks.
    private(set) var lastRenderDuration: CFTimeInterval = 0

    init(editor: Editor) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.drawsAsynchronously = false
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)])
        spatialIndex.rebuild(editor.scene.elements)
        observerToken = editor.scene.observe { [weak self] change in self?.sceneChanged(change) }
        editor.needsDisplay = { [weak self] in
            self?.needsDisplay = true
            self?.updateAccessibilityValue()
        }
        editor.viewportDidChange = { [weak self] in self?.viewportChanged() }
        editor.toolDidChange = { [weak self] in self?.toolChanged() }
        editor.beginTextEditing = { [weak self] id, isNew in self?.beginTextEditing(id, isNew: isNew) }
        editor.focusCanvas = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
        editor.requestFrameRename = { [weak self] id in self?.beginRenamingFrame(id) }
        editor.requestTextCreation = { [weak self] p in
            guard let self else { return }
            self.commitTextEditing()
            self.window?.makeFirstResponder(self)
            self.interaction.createText(at: p, centered: true)
        }
        editor.commands.willPerformCommand = { [weak self] in
            self?.commitTextEditing()
            self?.interaction.cancel()
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel("Canvas")
        setAccessibilityIdentifier("canvas")
        updateAccessibilityValue()
    }

    private func updateAccessibilityValue() {
        let n = editor.scene.count
        let sel = editor.selection.count
        var v = "\(n) element\(n == 1 ? "" : "s")"
        if sel > 0 { v += ", \(sel) selected" }
        setAccessibilityValue(v)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let t = observerToken { MainActor.assumeIsolated { editor.scene.removeObserver(t) } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Become first responder once the canvas is actually inside a window (SwiftUI inserts
        // it after the window controller shows the window).
        if let window, window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(self)
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Model observation

    private func sceneChanged(_ change: SceneChange) {
        if change.reset || (change.structural && change.changedIDs.count > 2000) {
            spatialIndex.rebuild(editor.scene.elements)
            if change.reset { geometryCache.removeAll() }
        } else {
            for id in change.removedIDs { spatialIndex.remove(id) }
            geometryCache.invalidate(change.removedIDs)
            for id in change.changedIDs {
                if let e = editor.scene.element(id) { spatialIndex.insert(id, e.renderBounds) } else { spatialIndex.remove(id) }
            }
        }
        if let id = editor.editingTextID { textEditor?.syncFrame(for: id) }
        if change.structural { updateAccessibilityValue() }
        needsDisplay = true
    }

    private func viewportChanged() {
        textEditor?.syncFrame(for: editor.editingTextID)
        positionFrameRenamer()
        needsDisplay = true
    }

    private func toolChanged() {
        if editor.tool != .select && editor.tool != .hand && !(editor.tool == .text && editor.editingTextID != nil) {
            commitTextEditing()
        }
        if editor.tool == .image {
            chooseImage(at: editor.visibleCenter)
        }
        updateCursor()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let old = bounds.size
        super.setFrameSize(newSize)
        editor.viewSize = newSize
        if !didInitialFit, newSize.width > 50, newSize.height > 50 {
            didInitialFit = true
            if editor.scene.count > 0 {
                editor.viewport = .fitting(CGRect.union(editor.scene.elements.map(\.bounds)) ?? .zero, viewSize: newSize, maxZoom: 1)
            } else {
                editor.viewport = CanvasViewport(origin: CGPoint(x: -newSize.width / 2, y: -newSize.height / 2), zoom: 1)
            }
        } else if old.width > 0 {
            // Keep the content centered while the window resizes.
            var v = editor.viewport
            v.origin.x -= (newSize.width - old.width) / 2 / v.zoom
            v.origin.y -= (newSize.height - old.height) / 2 / v.zoom
            editor.viewport = v
        }
    }

    /// Applies a viewport restored from window state, taking precedence over the initial fit.
    func restoreViewport(_ v: CanvasViewport) {
        didInitialFit = true
        editor.viewport = v
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    var isDark: Bool { editor.isDarkCanvas }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let start = CACurrentMediaTime()
        let dark = isDark
        let v = editor.viewport
        let scene = editor.scene

        ctx.setFillColor(scene.settings.background?.cgColor(dark: dark) ?? CanvasTheme.background(dark: dark))
        ctx.fill(bounds)
        drawGrid(ctx, viewport: v, dark: dark)

        // Elements (world space, culled).
        let visible = v.visibleWorldRect(viewSize: bounds.size).expanded(by: v.worldLength(2))
        let ids = spatialIndex.query(visible)
        var indexed: [(Int, Element)] = []
        indexed.reserveCapacity(ids.count)
        for id in ids { if let i = scene.index(of: id) { indexed.append((i, scene.elements[i])) } }
        indexed.sort { $0.0 < $1.0 }
        var options = RenderOptions(dark: dark, zoom: v.zoom)
        options.levelOfDetail = true
        options.selectedIDs = editor.selection
        if let t = editor.editingTextID { options.hiddenIDs.insert(t) }
        let erasing = interaction.erasing

        ctx.saveGState()
        ctx.concatenate(v.transform)
        if erasing.isEmpty {
            SceneRenderer.draw(indexed.map(\.1), scene: scene, frameLookup: scene.element, in: ctx, cache: geometryCache, assets: editor.assets, options: options)
        } else {
            for (_, e) in indexed {
                if erasing.contains(e.id) { ctx.setAlpha(0.25) }
                SceneRenderer.draw([e], scene: scene, frameLookup: scene.element, in: ctx, cache: geometryCache, assets: editor.assets, options: options)
                ctx.setAlpha(1)
            }
        }
        ctx.restoreGState()

        drawOverlay(ctx, viewport: v, dark: dark)
        lastRenderDuration = CACurrentMediaTime() - start
    }

    private func drawGrid(_ ctx: CGContext, viewport v: CanvasViewport, dark: Bool) {
        guard editor.gridStyle != .none else { return }
        var spacing = CGFloat(editor.gridSpacing)
        // Grow the grid in powers of 5 when zoomed out so it never turns into noise.
        while spacing * v.zoom < 12 { spacing *= 5 }
        let screenSpacing = spacing * v.zoom
        let majorEvery = 5
        let visible = v.visibleWorldRect(viewSize: bounds.size)
        let x0 = Int((visible.minX / spacing).rounded(.down)), x1 = Int((visible.maxX / spacing).rounded(.up))
        let y0 = Int((visible.minY / spacing).rounded(.down)), y1 = Int((visible.maxY / spacing).rounded(.up))
        guard (x1 - x0) * (y1 - y0) < 40_000 || editor.gridStyle == .lines else { return }
        // Fade minor lines in as they spread out.
        let fade = min(1, max(0, (screenSpacing - 12) / 18))
        switch editor.gridStyle {
        case .none:
            break
        case .dots:
            // Scrawl's dot motif: fine dots, with small crosses marking major intersections.
            let minor = CanvasTheme.gridColor(dark: dark, major: false).copy(alpha: (dark ? 0.15 : 0.17) * (0.35 + 0.65 * fade)) ?? .black
            let major = CanvasTheme.gridColor(dark: dark, major: true)
            let dots = CGMutablePath()
            let crosses = CGMutablePath()
            for xi in x0...x1 {
                for yi in y0...y1 {
                    let p = v.toScreen(CGPoint(x: CGFloat(xi) * spacing, y: CGFloat(yi) * spacing))
                    if xi % majorEvery == 0 && yi % majorEvery == 0 {
                        let cx = p.x.rounded() + 0.5, cy = p.y.rounded() + 0.5
                        crosses.move(to: CGPoint(x: cx - 3, y: cy)); crosses.addLine(to: CGPoint(x: cx + 3, y: cy))
                        crosses.move(to: CGPoint(x: cx, y: cy - 3)); crosses.addLine(to: CGPoint(x: cx, y: cy + 3))
                    } else {
                        dots.addRect(CGRect(x: p.x.rounded() - 0.5, y: p.y.rounded() - 0.5, width: 1.25, height: 1.25))
                    }
                }
            }
            ctx.addPath(dots)
            ctx.setFillColor(minor)
            ctx.fillPath()
            ctx.addPath(crosses)
            ctx.setStrokeColor(major)
            ctx.setLineWidth(1)
            ctx.strokePath()
        case .lines:
            ctx.setLineWidth(1)
            for major in [false, true] {
                ctx.setStrokeColor(CanvasTheme.gridColor(dark: dark, major: major).copy(alpha: (major ? 1 : fade) * CanvasTheme.gridColor(dark: dark, major: major).alpha) ?? .black)
                for xi in x0...x1 where (xi % majorEvery == 0) == major {
                    let x = (v.toScreen(CGPoint(x: CGFloat(xi) * spacing, y: 0)).x).rounded() + 0.5
                    ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height))
                }
                for yi in y0...y1 where (yi % majorEvery == 0) == major {
                    let y = (v.toScreen(CGPoint(x: 0, y: CGFloat(yi) * spacing)).y).rounded() + 0.5
                    ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.width, y: y))
                }
                ctx.strokePath()
            }
        }
    }

    private var accentColor: CGColor {
        CanvasTheme.selection(highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
    }

    private func drawOverlay(_ ctx: CGContext, viewport v: CanvasViewport, dark: Bool) {
        let accent = accentColor
        let scene = editor.scene

        // Hover outline.
        if let id = hoverID, let e = scene.element(id), !interaction.isActive {
            outline(e, ctx: ctx, viewport: v, color: accent.copy(alpha: 0.45) ?? accent, width: 1)
        }
        // Connector target highlight.
        if let id = interaction.bindingHighlight, let e = scene.element(id) {
            outline(e, ctx: ctx, viewport: v, color: accent.copy(alpha: 0.6) ?? accent, width: 4, padding: 4)
        }
        if let id = editor.croppingImageID, let e = scene.element(id), let full = TransformMath.uncroppedRect(e),
           case let .image(img) = e.kind, let image = editor.assets.image(img.assetID) {
            // Show the hidden parts of the image faintly while cropping.
            ctx.saveGState()
            ctx.concatenate(v.transform)
            ctx.translateBy(x: e.center.x, y: e.center.y)
            ctx.rotate(by: e.rotation)
            ctx.translateBy(x: -e.center.x, y: -e.center.y)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            image.draw(in: full, from: .zero, operation: .sourceOver, fraction: 0.28, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            ctx.setStrokeColor(accent.copy(alpha: 0.5) ?? accent)
            ctx.setLineWidth(1 / v.zoom)
            ctx.setLineDash(phase: 0, lengths: [4 / v.zoom, 4 / v.zoom])
            ctx.stroke(full)
            ctx.restoreGState()
        }
        if editor.tool == .select && editor.editingTextID == nil {
            SelectionOverlay(editor: editor).draw(in: ctx, viewport: v, accent: accent, dark: dark)
        }
        // Snap guides: amber, with small cross ticks at each end.
        if !editor.snapGuides.isEmpty {
            let guideColor = CanvasTheme.guide(dark: dark)
            ctx.setStrokeColor(guideColor)
            ctx.setLineWidth(1)
            func tick(_ p: CGPoint) {
                ctx.move(to: CGPoint(x: p.x - 3, y: p.y - 3)); ctx.addLine(to: CGPoint(x: p.x + 3, y: p.y + 3))
                ctx.move(to: CGPoint(x: p.x - 3, y: p.y + 3)); ctx.addLine(to: CGPoint(x: p.x + 3, y: p.y - 3))
            }
            for g in editor.snapGuides {
                switch g {
                case let .line(a, b):
                    let sa = v.toScreen(a), sb = v.toScreen(b)
                    ctx.move(to: CGPoint(x: sa.x.rounded() + 0.5, y: sa.y.rounded() + 0.5))
                    ctx.addLine(to: CGPoint(x: sb.x.rounded() + 0.5, y: sb.y.rounded() + 0.5))
                    tick(sa); tick(sb)
                    ctx.strokePath()
                case let .spacing(marks):
                    var i = 0
                    ctx.setLineDash(phase: 0, lengths: [2, 2])
                    while i + 1 < marks.count {
                        let a = v.toScreen(marks[i]), b = v.toScreen(marks[i + 1])
                        ctx.move(to: a); ctx.addLine(to: b)
                        i += 2
                    }
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                    i = 0
                    while i + 1 < marks.count {
                        let a = v.toScreen(marks[i]), b = v.toScreen(marks[i + 1])
                        let n = (b - a).normalized
                        let perp = CGPoint(x: -n.y, y: n.x) * 4
                        ctx.move(to: a + perp); ctx.addLine(to: a - perp)
                        ctx.move(to: b + perp); ctx.addLine(to: b - perp)
                        i += 2
                    }
                    ctx.strokePath()
                }
            }
        }
        // Marquee: dashed accent hairline over a faint wash.
        if let r = interaction.marqueeRect {
            let sr = v.toScreen(r)
            ctx.setFillColor(accent.copy(alpha: 0.06) ?? accent)
            ctx.fill(sr)
            ctx.setStrokeColor(accent.copy(alpha: 0.8) ?? accent)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(sr.insetBy(dx: 0.5, dy: 0.5))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // Live dimensions while resizing or drawing a shape.
        if interaction.showsDimensions, let e = editor.selectedElements.first, editor.selection.count == 1 {
            drawDimensionChip(for: e, ctx: ctx, viewport: v, accent: accent)
        }
    }

    private func drawDimensionChip(for e: Element, ctx: CGContext, viewport v: CanvasViewport, accent: CGColor) {
        let text = "\(Int(e.frame.width.rounded())) × \(Int(e.frame.height.rounded()))"
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = attr.size()
        let b = v.toScreen(e.bounds)
        let chip = CGRect(x: b.midX - size.width / 2 - 6, y: b.maxY + 8, width: size.width + 12, height: size.height + 4)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: chip.height / 2, cornerHeight: chip.height / 2, transform: nil))
        ctx.setFillColor(accent)
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attr.draw(at: CGPoint(x: chip.minX + 6, y: chip.minY + 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func outline(_ e: Element, ctx: CGContext, viewport v: CanvasViewport, color: CGColor, width: CGFloat, padding: CGFloat = 0) {
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if e.isLinear || e.type == .freehand {
            let pts = e.worldPoints.map(v.toScreen)
            if e.isLinear, let d = e.linear {
                let route = ElementGeometry.route(d, routing: e.style.routing).map { v.toScreen($0 + e.frame.origin) }
                ctx.addLines(between: route)
            } else {
                ctx.addLines(between: pts)
            }
        } else {
            let corners = e.frame.expanded(by: padding / v.zoom).rotatedCorners(e.rotation).map(v.toScreen)
            ctx.addLines(between: corners)
            ctx.closePath()
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseDown(with event: NSEvent) {
        if editor.editingTextID != nil { commitTextEditing() }
        finishFrameRename(commit: true)
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        hoverID = nil
        interaction.mouseDown(event)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        interaction.mouseDragged(event)
        autoscroll(event)
    }

    override func mouseUp(with event: NSEvent) {
        interaction.mouseUp(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-button drag pans.
        guard event.buttonNumber == 2 else { return }
        interaction.beginPan(at: convert(event.locationInWindow, from: nil))
        updateCursor()
    }

    override func otherMouseDragged(with event: NSEvent) { interaction.mouseDragged(event) }
    override func otherMouseUp(with event: NSEvent) { interaction.mouseUp(event) }

    override func mouseMoved(with event: NSEvent) {
        let s = convert(event.locationInWindow, from: nil)
        let newHover = interaction.hoverElement(at: s)
        if newHover != hoverID {
            hoverID = newHover
            needsDisplay = true
        }
        interaction.cursor(at: s, flags: event.modifierFlags).set()
    }

    override func mouseExited(with event: NSEvent) {
        if hoverID != nil { hoverID = nil; needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) {
        interaction.cursor(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags).set()
    }

    func updateCursor() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(p) else { return }
        interaction.cursor(at: p, flags: NSEvent.modifierFlags).set()
    }

    /// Dragging past the edge scrolls the canvas.
    private func autoscroll(_ event: NSEvent) {
        guard !interaction.isPanning else { return }
        let p = convert(event.locationInWindow, from: nil)
        let margin: CGFloat = 12
        var d = CGPoint.zero
        if p.x < margin { d.x = margin - p.x } else if p.x > bounds.width - margin { d.x = bounds.width - margin - p.x }
        if p.y < margin { d.y = margin - p.y } else if p.y > bounds.height - margin { d.y = bounds.height - margin - p.y }
        guard d != .zero else { return }
        var v = editor.viewport
        v.pan(byScreenDelta: CGPoint(x: max(-20, min(20, d.x)), y: max(-20, min(20, d.y))))
        editor.viewport = v
    }

    // MARK: Trackpad & wheel navigation

    override func scrollWheel(with event: NSEvent) {
        let s = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        let zoomModifier = flags.contains(.command) || flags.contains(.control)
        var v = editor.viewport
        if event.hasPreciseScrollingDeltas {
            if zoomModifier {
                let factor = exp(-event.scrollingDeltaY * 0.01)
                v.zoom(to: v.zoom * factor, anchor: s)
            } else {
                // Two-finger pan, including momentum phases delivered by AppKit.
                v.pan(byScreenDelta: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY))
            }
        } else {
            let wheelZooms = Preferences.shared.scrollWheelZooms != zoomModifier
            if wheelZooms {
                let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
                v.zoom(to: v.zoom * pow(1.12, delta), anchor: s)
            } else {
                let line: CGFloat = 24
                var dx = event.scrollingDeltaX * line, dy = event.scrollingDeltaY * line
                if flags.contains(.shift) && dx == 0 { dx = dy; dy = 0 }
                v.pan(byScreenDelta: CGPoint(x: dx, y: dy))
            }
        }
        editor.viewport = v
    }

    override func magnify(with event: NSEvent) {
        let s = convert(event.locationInWindow, from: nil)
        var v = editor.viewport
        v.zoom(to: v.zoom * (1 + event.magnification), anchor: s)
        editor.viewport = v
    }

    /// Two-finger rotation turns the selection; the whole gesture is one undo step.
    private var rotationGesture: (originals: [ElementID: Element], pivot: CGPoint, angle: CGFloat)?

    override func rotate(with event: NSEvent) {
        switch event.phase {
        case .began:
            let els = editor.selectedElements.filter { !$0.isLocked && !$0.isFrame }
            guard !els.isEmpty, let box = CGRect.union(els.map(\.bounds)) else { return }
            editor.commands.beginInteractive("Rotate")
            rotationGesture = (Dictionary(uniqueKeysWithValues: els.map { ($0.id, $0) }), els.count == 1 ? els[0].center : box.center, 0)
        case .changed:
            guard var g = rotationGesture else { return }
            // AppKit reports counter-clockwise degrees; the canvas is y-down.
            g.angle -= CGFloat(event.rotation) * .pi / 180
            rotationGesture = g
            var angle = g.angle
            if event.modifierFlags.contains(.shift) { angle = Geometry.snapAngle(angle) }
            TransformMath.rotate(Set(g.originals.keys), by: angle, around: g.pivot, in: editor.scene, originals: g.originals)
        case .ended, .cancelled:
            guard rotationGesture != nil else { return }
            rotationGesture = nil
            editor.commands.endInteractive()
        default:
            break
        }
    }

    override func smartMagnify(with event: NSEvent) {
        let s = convert(event.locationInWindow, from: nil)
        var v = editor.viewport
        v.zoom(to: abs(v.zoom - 1) < 0.01 ? 2 : 1, anchor: s)
        editor.setViewport(v, animated: true)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let plain = flags.subtracting([.shift, .function, .numericPad, .capsLock]).isEmpty

        switch event.keyCode {
        case 49: // space
            if !isSpaceHeld {
                isSpaceHeld = true
                updateCursor()
            }
            return
        case 53: // escape
            if editor.focusMode && !interaction.isActive && editor.selection.isEmpty { editor.toggleFocusMode(); return }
            if editor.croppingImageID != nil && !interaction.isActive { editor.endCrop() }
            else if interaction.isActive { interaction.cancel() }
            else if !editor.selection.isEmpty { editor.clearSelection() }
            else if editor.tool != .select { editor.tool = .select }
            return
        case 51, 117: // delete, forward delete
            editor.deleteSelection()
            return
        case 36, 76: // return
            if editor.croppingImageID != nil { editor.endCrop(); return }
            if plain, let e = editor.selectedElements.first, editor.selection.count == 1 {
                if e.type == .image { editor.beginCrop(e.id) }
                else if e.isText { editor.startEditingText(e.id, isNew: false) }
                else if e.isFrame { beginRenamingFrame(e.id) }
            }
            return
        case 123, 124, 125, 126: // arrows
            guard plain else { break }
            let step: CGFloat = flags.contains(.shift) ? (editor.gridStyle != .none ? CGFloat(editor.gridSpacing) : 10) : 1
            let d: CGPoint
            switch event.keyCode {
            case 123: d = CGPoint(x: -step, y: 0)
            case 124: d = CGPoint(x: step, y: 0)
            case 125: d = CGPoint(x: 0, y: step)
            default: d = CGPoint(x: 0, y: -step)
            }
            if editor.selection.isEmpty {
                var v = editor.viewport
                v.pan(byScreenDelta: -d * 4)
                editor.viewport = v
            } else {
                editor.nudge(d)
            }
            return
        default:
            break
        }

        if plain, let c = chars.first {
            if flags.contains(.shift) {
                switch c {
                case "!", "1": editor.zoomToFit(); return
                case "@", "2": editor.zoomToSelection(); return
                case "?", "/": editor.shortcutsVisible.toggle(); return
                default: break
                }
            }
            if c == "q" && !flags.contains(.shift) {
                editor.toolLocked.toggle()
                editor.showToast(editor.toolLocked ? "Tool locked" : "Tool unlocked", symbol: editor.toolLocked ? "lock" : "lock.open")
                return
            }
            if !flags.contains(.shift), let tool = Tool.forKey(c) {
                editor.tool = tool
                return
            }
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            isSpaceHeld = false
            updateCursor()
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        updateCursor()
    }

    override func resignFirstResponder() -> Bool {
        isSpaceHeld = false
        return super.resignFirstResponder()
    }

    // MARK: Standard edit actions
    // Handled here (and forwarded) so intermediate SwiftUI responders can't swallow them.

    private var controller: DocumentWindowController? { window?.windowController as? DocumentWindowController }

    @objc func copy(_ sender: Any?) { controller?.copy(sender) }
    @objc func cut(_ sender: Any?) { controller?.cut(sender) }
    @objc func paste(_ sender: Any?) { controller?.paste(sender) }
    @objc func delete(_ sender: Any?) { controller?.delete(sender) }
    @objc override func selectAll(_ sender: Any?) { controller?.selectAll(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        controller?.validateMenuItem(item) ?? false
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let s = convert(event.locationInWindow, from: nil)
        let p = editor.viewport.toWorld(s)
        if let hit = interaction.hitTest(p) {
            if !editor.selection.contains(hit.id) { editor.select(SceneOps.expandToGroups([hit.id], in: editor.scene)) }
        }
        return ContextMenuBuilder.menu(for: editor, at: p)
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                                                  .urlReadingContentsConformToTypes: [UTType.image.identifier]]) { return true }
        return pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let p = editor.viewport.toWorld(convert(sender.draggingLocation, from: nil))
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                                                         .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL], !urls.isEmpty {
            return editor.insertImages(from: urls, at: p)
        }
        if case let .images(items) = Clipboard.read(pb) {
            return editor.insertImages(items, at: p)
        }
        return false
    }

    // MARK: Images

    func chooseImage(at world: CGPoint) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AssetStore.importableTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose images to insert"
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK { _ = self.editor.insertImages(from: panel.urls, at: world) }
            if self.editor.tool == .image { self.editor.tool = .select }
        }
    }

    // MARK: Text editing

    private func beginTextEditing(_ id: ElementID, isNew: Bool) {
        commitTextEditingIfOther(than: id)
        guard let e = editor.scene.element(id), e.isText else { return }
        if !isNew { editor.commands.beginInteractive("Edit Text") }
        let overlay = TextEditorOverlay(canvas: self, elementID: id, isNew: isNew)
        textEditor = overlay
        overlay.install()
        needsDisplay = true
    }

    private func commitTextEditingIfOther(than id: ElementID) {
        if let t = textEditor, t.elementID != id { commitTextEditing() }
    }

    func commitTextEditing() {
        guard let t = textEditor else { return }
        textEditor = nil
        t.commit()
        editor.didEndEditingText()
        window?.makeFirstResponder(self)
        if !editor.toolLocked && editor.tool == .text { editor.tool = .select }
    }

    // MARK: Frame renaming

    func beginRenamingFrame(_ id: ElementID) {
        finishFrameRename(commit: true)
        guard let e = editor.scene.element(id), let f = e.frameData else { return }
        let field = NSTextField(string: f.name)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.target = self
        field.action = #selector(frameRenameAction(_:))
        field.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        field.wantsLayer = true
        field.layer?.cornerRadius = 4
        addSubview(field)
        frameRenamer = field
        positionFrameRenamer()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private func positionFrameRenamer() {
        guard let field = frameRenamer, let idString = field.identifier?.rawValue, let id = UUID(uuidString: idString),
              let e = editor.scene.element(id) else { return }
        let r = editor.viewport.toScreen(SceneRenderer.frameLabelRect(for: e, zoom: editor.viewport.zoom))
        field.frame = CGRect(x: r.minX - 2, y: r.minY - 2, width: max(140, min(r.width, 320)), height: 20)
    }

    @objc private func frameRenameAction(_ sender: NSTextField) {
        finishFrameRename(commit: true)
    }

    func finishFrameRename(commit: Bool) {
        guard let field = frameRenamer else { return }
        frameRenamer = nil
        if commit, let idString = field.identifier?.rawValue, let id = UUID(uuidString: idString) {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { editor.renameFrame(id, to: name) }
        }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    override func cancelOperation(_ sender: Any?) {
        if frameRenamer != nil { finishFrameRename(commit: false) }
    }
}
