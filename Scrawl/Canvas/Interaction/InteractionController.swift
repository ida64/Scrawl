import AppKit

/// Pointer interaction modelled as an explicit state machine. Every gesture is one state; live
/// changes go through an interactive transaction so each gesture is a single undo step.
final class InteractionController {
    enum State {
        case idle
        case panning(last: CGPoint)
        case pressingSelection(PressState)
        case dragging(DragState)
        case resizing(ResizeState)
        case rotating(RotateState)
        case marquee(MarqueeState)
        case creatingShape(CreateState)
        case creatingLinear(LinearCreateState)
        case drawingFreehand(FreehandState)
        case draggingEndpoint(EndpointState)
        case erasing(Set<ElementID>)
    }

    struct PressState {
        var startScreen: CGPoint
        var startWorld: CGPoint
        var ids: Set<ElementID>
        var duplicate: Bool
        /// Element clicked while already selected; on mouse-up without drag, narrow to it.
        var narrowTo: Set<ElementID>?
    }

    struct DragState {
        var startWorld: CGPoint
        var applied: CGPoint
        var ids: Set<ElementID>
        var box: CGRect
        var candidates: [CGRect]
    }

    struct ResizeState {
        var handle: Handle
        var originals: [Element]
        var box: CGRect
        var started = false
        var candidates: [CGRect]
    }

    struct RotateState {
        var pivot: CGPoint
        var startAngle: CGFloat
        var originals: [ElementID: Element]
        var baseRotation: CGFloat
        var started = false
    }

    struct MarqueeState {
        var start: CGPoint
        var current: CGPoint
        var base: Set<ElementID>
    }

    struct CreateState {
        var id: ElementID
        var origin: CGPoint
        var startScreen: CGPoint
    }

    struct LinearCreateState {
        var id: ElementID
        var origin: CGPoint
        var startBinding: ConnectorBinding?
        var startScreen: CGPoint
    }

    struct FreehandState {
        var id: ElementID
        var points: [CGPoint]
        var pressures: [Double]
        var lastTime: TimeInterval
        var hasRealPressure: Bool
    }

    struct EndpointState {
        var id: ElementID
        var isStart: Bool
        var original: Element
        var started = false
    }

    private(set) var state: State = .idle
    unowned let canvas: CanvasView
    var editor: Editor { canvas.editor }
    private var scene: Scene { editor.scene }

    /// Connector target highlighted while dragging an arrow end.
    private(set) var bindingHighlight: ElementID?
    /// Elements under the eraser (rendered faded until mouse-up).
    var erasing: Set<ElementID> {
        if case let .erasing(ids) = state { return ids }
        return []
    }

    var marqueeRect: CGRect? {
        if case let .marquee(m) = state { return CGRect(corner: m.start, m.current) }
        return nil
    }

    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }

    /// Whether the canvas should show a live size readout.
    var showsDimensions: Bool {
        switch state {
        case .resizing, .creatingShape: return true
        default: return false
        }
    }

    var isPanning: Bool {
        if case .panning = state { return true }
        return false
    }

    init(canvas: CanvasView) {
        self.canvas = canvas
    }

    // MARK: Helpers

    private var tolerance: CGFloat { editor.viewport.worldLength(6) }

    private func world(_ event: NSEvent) -> CGPoint {
        editor.viewport.toWorld(canvas.convert(event.locationInWindow, from: nil))
    }

    private func screen(_ event: NSEvent) -> CGPoint {
        canvas.convert(event.locationInWindow, from: nil)
    }

    private func snapEngine(_ event: NSEvent) -> SnapEngine? {
        // Holding ⌘ temporarily disables snapping.
        guard !event.modifierFlags.contains(.command) else { return nil }
        let prefs = Preferences.shared
        let grid = prefs.snapToGrid && editor.gridStyle != .none ? CGFloat(editor.gridSpacing) : nil
        guard editor.snapEnabled || grid != nil else { return nil }
        var s = SnapEngine(tolerance: editor.viewport.worldLength(7), gridSpacing: grid)
        s.snapToObjects = editor.snapEnabled
        return s
    }

    /// Bounds of visible elements not in `excluding`, used as snap targets.
    private func snapCandidates(excluding: Set<ElementID>) -> [CGRect] {
        let visible = editor.viewport.visibleWorldRect(viewSize: canvas.bounds.size)
        let ids = canvas.spatialIndex.query(visible)
        var out: [CGRect] = []
        out.reserveCapacity(min(ids.count, 1500))
        for id in ids where !excluding.contains(id) {
            guard let e = scene.element(id), !e.isLinear, e.type != .freehand else { continue }
            out.append(e.bounds)
            if out.count >= 1500 { break }
        }
        return out
    }

    /// Topmost element under a world point.
    func hitTest(_ p: CGPoint, includeLocked: Bool = true) -> Element? {
        let ids = canvas.spatialIndex.query(CGRect(center: p, size: CGSize(width: tolerance * 2 + 2, height: tolerance * 2 + 2)))
        let candidates = ids.compactMap { id in scene.index(of: id).map { ($0, id) } }.sorted { $0.0 > $1.0 }
        // Non-frame elements take priority over frame borders.
        var frameHit: Element?
        for (_, id) in candidates {
            guard let e = scene.element(id), !e.isHidden else { continue }
            if !includeLocked && e.isLocked { continue }
            let selected = editor.selection.contains(id)
            if HitTester.hits(e, p, tolerance: tolerance, selected: selected) {
                if e.isFrame { frameHit = frameHit ?? e; continue }
                return e
            }
        }
        if let f = frameHit { return f }
        // Frame name labels are clickable too.
        for e in scene.elements.reversed() where e.isFrame && !e.isHidden {
            if SceneRenderer.frameLabelRect(for: e, zoom: editor.viewport.zoom).contains(p) { return e }
        }
        return nil
    }

    private func selectionTarget(for e: Element, deep: Bool) -> Set<ElementID> {
        if deep { return [e.id] }
        return SceneOps.expandToGroups([e.id], in: scene)
    }

    // MARK: Mouse down

    func beginPan(at screen: CGPoint) {
        state = .panning(last: screen)
    }

    func mouseDown(_ event: NSEvent) {
        let p = world(event)
        let s = screen(event)

        if canvas.isSpaceHeld || editor.tool == .hand {
            state = .panning(last: s)
            canvas.updateCursor()
            return
        }

        switch editor.tool {
        case .select:
            selectMouseDown(event, p, s)
        case .rectangle, .ellipse, .diamond, .frame:
            beginShape(event, p, s)
        case .arrow, .line:
            beginLinear(event, p, s)
        case .pencil:
            beginFreehand(event, p)
        case .text:
            if let hit = hitTest(p), hit.isText, !hit.isLocked {
                editor.select([hit.id])
                editor.startEditingText(hit.id, isNew: false)
            } else {
                createText(at: p)
            }
        case .image:
            canvas.chooseImage(at: p)
        case .eraser:
            state = .erasing([])
            erase(at: p)
        case .hand:
            break
        }
    }

    private func selectMouseDown(_ event: NSEvent, _ p: CGPoint, _ s: CGPoint) {
        let overlay = SelectionOverlay(editor: editor)
        if event.clickCount == 1, let handle = overlay.handle(at: s) {
            beginHandleDrag(handle)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        let deep = event.modifierFlags.contains(.command)
        let hit = hitTest(p)

        if event.clickCount >= 2 {
            handleDoubleClick(hit, at: p)
            return
        }

        guard let hit else {
            if !shift { editor.clearSelection() }
            state = .marquee(MarqueeState(start: p, current: p, base: shift ? editor.selection : []))
            return
        }

        let target = selectionTarget(for: hit, deep: deep)
        var narrow: Set<ElementID>?
        if shift {
            if editor.selection.isSuperset(of: target) {
                editor.select(editor.selection.subtracting(target))
                return
            }
            editor.select(editor.selection.union(target))
        } else if !editor.selection.isSuperset(of: target) {
            editor.select(target)
        } else if editor.selection != target {
            narrow = target
        }
        let movable = SceneOps.unlocked(editor.selection, in: scene)
        state = .pressingSelection(PressState(startScreen: s, startWorld: p, ids: movable,
                                              duplicate: event.modifierFlags.contains(.option), narrowTo: narrow))
    }

    private func handleDoubleClick(_ hit: Element?, at p: CGPoint) {
        guard let hit else {
            createText(at: p)
            return
        }
        if hit.type == .image && !hit.isLocked {
            editor.beginCrop(hit.id)
        } else if hit.isText && !hit.isLocked {
            editor.select([hit.id])
            editor.startEditingText(hit.id, isNew: false)
        } else if hit.isFrame {
            editor.select([hit.id])
            canvas.beginRenamingFrame(hit.id)
        } else if hit.groupIDs.count > 0 {
            // Double-click enters a group, selecting the element itself.
            editor.select([hit.id])
        } else if hit.supportsFill && !hit.isLocked {
            // Double-click a shape to add a centered label.
            createText(at: hit.center, centered: true)
        }
    }

    private func beginHandleDrag(_ handle: Handle) {
        let els = editor.selectedElements.filter { !$0.isLocked }
        guard !els.isEmpty else { return }
        switch handle {
        case .rotation:
            let box = CGRect.union(els.map(\.bounds)) ?? .zero
            let pivot = els.count == 1 ? els[0].center : box.center
            state = .rotating(RotateState(pivot: pivot, startAngle: .nan, originals: Dictionary(uniqueKeysWithValues: els.map { ($0.id, $0) }),
                                          baseRotation: els.count == 1 ? els[0].rotation : 0))
        case .lineStart, .lineEnd:
            guard let e = els.first else { return }
            state = .draggingEndpoint(EndpointState(id: e.id, isStart: handle == .lineStart, original: e))
        default:
            let box = els.count == 1 ? els[0].frame : (CGRect.union(els.map(\.bounds)) ?? .zero)
            state = .resizing(ResizeState(handle: handle, originals: els, box: box,
                                          candidates: snapCandidates(excluding: Set(els.map(\.id)))))
        }
    }

    // MARK: Creation

    private func beginShape(_ event: NSEvent, _ p: CGPoint, _ s: CGPoint) {
        var origin = p
        if let snap = snapEngine(event) { origin += snap.snap(point: p, against: snapCandidates(excluding: [])).offset }
        let type: ElementType
        switch editor.tool {
        case .ellipse: type = .ellipse
        case .diamond: type = .diamond
        case .frame: type = .frame
        default: type = .rectangle
        }
        let e = editor.makeElement(type, frame: CGRect(origin: origin, size: .zero))
        editor.commands.beginInteractive("Add \(type.displayName)")
        if type == .frame { scene.insert([e], at: 0) } else { scene.insert([e]) }
        editor.select([e.id])
        state = .creatingShape(CreateState(id: e.id, origin: origin, startScreen: s))
    }

    private func beginLinear(_ event: NSEvent, _ p: CGPoint, _ s: CGPoint) {
        let type: ElementType = editor.tool == .arrow ? .arrow : .line
        var origin = p
        var startBinding: ConnectorBinding?
        let candidates = scene.elements(canvas.spatialIndex.query(CGRect(center: p, size: CGSize(width: 40, height: 40))))
        if let (target, anchor) = BindingSolver.target(at: p, in: scene, candidates: candidates, excluding: [], tolerance: tolerance) {
            startBinding = ConnectorBinding(elementID: target.id, anchor: anchor)
        } else if let snap = snapEngine(event) {
            origin += snap.snap(point: p, against: snapCandidates(excluding: [])).offset
        }
        var e = editor.makeElement(type, frame: CGRect(origin: origin, size: .zero))
        e.setLinearWorldPoints([origin, origin])
        editor.commands.beginInteractive("Add \(type.displayName)")
        scene.insert([e])
        editor.select([e.id])
        state = .creatingLinear(LinearCreateState(id: e.id, origin: origin, startBinding: startBinding, startScreen: s))
    }

    private func beginFreehand(_ event: NSEvent, _ p: CGPoint) {
        var e = editor.makeElement(.freehand, frame: CGRect(origin: p, size: .zero))
        let real = event.subtype == .tabletPoint && event.pressure > 0
        let pr = real ? Double(event.pressure) : 0.5
        e.kind = .freehand(FreehandData(points: [.zero], pressures: [pr]))
        editor.commands.beginInteractive("Draw")
        scene.insert([e])
        editor.clearSelection()
        state = .drawingFreehand(FreehandState(id: e.id, points: [p], pressures: [pr], lastTime: event.timestamp, hasRealPressure: real))
        NSEvent.isMouseCoalescingEnabled = false
    }

    func createText(at p: CGPoint, centered: Bool = false) {
        var e = editor.makeElement(.text, frame: CGRect(origin: p, size: .zero))
        if centered { e.style.textAlign = .center }
        TextLayout.fit(&e)
        e.frame.origin = centered ? CGPoint(x: p.x - e.frame.width / 2, y: p.y - e.frame.height / 2) : CGPoint(x: p.x, y: p.y - e.frame.height / 2)
        editor.commands.beginInteractive("Add Text")
        scene.insert([e])
        editor.select([e.id])
        editor.startEditingText(e.id, isNew: true)
    }

    // MARK: Mouse dragged

    func mouseDragged(_ event: NSEvent) {
        let p = world(event)
        let s = screen(event)
        switch state {
        case .idle:
            break
        case let .panning(last):
            var v = editor.viewport
            v.pan(byScreenDelta: s - last)
            editor.viewport = v
            state = .panning(last: s)
            canvas.updateCursor()
        case let .pressingSelection(press):
            guard s.distance(to: press.startScreen) >= 3, !press.ids.isEmpty else { return }
            startDrag(press)
            mouseDragged(event)
        case var .dragging(d):
            var delta = p - d.startWorld
            if event.modifierFlags.contains(.shift) {
                if abs(delta.x) > abs(delta.y) { delta.y = 0 } else { delta.x = 0 }
            }
            var guides: [SnapGuide] = []
            if let snap = snapEngine(event) {
                let r = snap.snap(moving: d.box.offsetBy(dx: delta.x, dy: delta.y), against: d.candidates)
                delta += r.offset
                guides = r.guides
            }
            let step = delta - d.applied
            if step != .zero {
                SceneOps.translate(d.ids, by: step, in: scene)
                d.applied = delta
            }
            editor.snapGuides = guides
            state = .dragging(d)
            canvas.needsDisplay = true
        case var .resizing(r):
            if !r.started {
                editor.commands.beginInteractive(editor.croppingImageID != nil ? "Crop" : "Resize")
                r.started = true
            }
            resize(&r, to: p, event: event)
            state = .resizing(r)
        case var .rotating(r):
            if !r.started {
                editor.commands.beginInteractive("Rotate")
                r.started = true
                r.startAngle = atan2(p.y - r.pivot.y, p.x - r.pivot.x)
            }
            var angle = atan2(p.y - r.pivot.y, p.x - r.pivot.x) - r.startAngle
            if event.modifierFlags.contains(.shift) {
                angle = Geometry.snapAngle(r.baseRotation + angle) - r.baseRotation
            }
            TransformMath.rotate(Set(r.originals.keys), by: angle, around: r.pivot, in: scene, originals: r.originals)
            state = .rotating(r)
        case var .marquee(m):
            m.current = p
            let rect = CGRect(corner: m.start, m.current)
            let touch = event.modifierFlags.contains(.option)
            var hits = Set<ElementID>()
            for id in canvas.spatialIndex.query(rect) {
                guard let e = scene.element(id), !e.isHidden else { continue }
                if touch ? HitTester.intersects(e, rect: rect) : HitTester.isEnclosed(e, by: rect) { hits.insert(id) }
            }
            // A partially captured group is not selected (Excalidraw semantics); full groups are.
            var result = m.base
            for id in hits {
                let group = SceneOps.expandToGroups([id], in: scene)
                if touch || group.isSubset(of: hits) { result.formUnion(group) }
            }
            editor.select(result)
            state = .marquee(m)
            canvas.needsDisplay = true
        case let .creatingShape(c):
            var q = p
            var guides: [SnapGuide] = []
            if let snap = snapEngine(event) {
                let r = snap.snap(point: p, against: snapCandidates(excluding: [c.id]))
                q += r.offset
                guides = r.guides
            }
            var rect = CGRect(corner: c.origin, q)
            if event.modifierFlags.contains(.shift) {
                let side = max(rect.width, rect.height)
                rect.size = CGSize(width: side, height: side)
                if q.x < c.origin.x { rect.origin.x = c.origin.x - side }
                if q.y < c.origin.y { rect.origin.y = c.origin.y - side }
            }
            if event.modifierFlags.contains(.option) {
                let dx = abs(q.x - c.origin.x), dy = abs(q.y - c.origin.y)
                var w = dx, h = dy
                if event.modifierFlags.contains(.shift) { w = max(dx, dy); h = w }
                rect = CGRect(x: c.origin.x - w, y: c.origin.y - h, width: w * 2, height: h * 2)
            }
            scene.update(c.id) { $0.frame = rect }
            editor.snapGuides = guides
        case let .creatingLinear(c):
            updateLinearCreation(c, to: p, event: event)
        case var .drawingFreehand(f):
            appendFreehand(&f, p, event)
            state = .drawingFreehand(f)
        case var .draggingEndpoint(ep):
            if !ep.started {
                editor.commands.beginInteractive("Edit Connector")
                ep.started = true
            }
            moveEndpoint(ep, to: p, event: event)
            state = .draggingEndpoint(ep)
        case .erasing:
            erase(at: p)
        }
    }

    private func startDrag(_ press: PressState) {
        var ids = SceneOps.expandFrames(press.ids, in: scene)
        if press.duplicate {
            editor.commands.beginInteractive("Duplicate")
            let source = scene.elements(ids)
            let copies = SceneOps.insertCopies(of: source, offset: .zero, in: scene)
            editor.select(Set(copies))
            ids = Set(copies)
        } else {
            editor.commands.beginInteractive("Move")
        }
        let box = SceneOps.selectionBounds(ids, in: scene) ?? .zero
        state = .dragging(DragState(startWorld: press.startWorld, applied: .zero, ids: ids, box: box,
                                    candidates: snapCandidates(excluding: ids)))
        canvas.updateCursor()
    }

    private func resize(_ r: inout ResizeState, to p: CGPoint, event: NSEvent) {
        let keep = event.modifierFlags.contains(.shift)
        let center = event.modifierFlags.contains(.option)
        var q = p
        var guides: [SnapGuide] = []
        if r.originals.count == 1 && r.originals[0].rotation == 0, let snap = snapEngine(event) {
            let res = snap.snap(point: p, against: r.candidates)
            q += res.offset
            guides = res.guides
        }
        editor.snapGuides = guides
        if r.originals.count == 1, let o = r.originals.first, editor.croppingImageID == o.id {
            scene.replace(TransformMath.crop(o, handle: r.handle, to: p))
            return
        }
        if r.originals.count == 1, let o = r.originals.first {
            scene.batch {
                scene.replace(TransformMath.resize(o, handle: r.handle, to: q, keepAspect: keep, fromCenter: center))
                BindingSolver.updateConnectors(in: scene, affectedBy: [o.id])
            }
        } else {
            let forceAspect = r.originals.contains { $0.isText || $0.type == .image }
            let raw = TransformMath.resizedBox(r.box, handle: r.handle, to: q, keepAspect: keep || forceAspect, fromCenter: center)
            var box = raw
            if abs(box.width) < 1 { box.size.width = box.width < 0 ? -1 : 1 }
            if abs(box.height) < 1 { box.size.height = box.height < 0 ? -1 : 1 }
            scene.batch {
                TransformMath.scale(r.originals, from: r.box, to: box, in: scene)
                BindingSolver.updateConnectors(in: scene, affectedBy: Set(r.originals.map(\.id)))
            }
        }
    }

    private func updateLinearCreation(_ c: LinearCreateState, to p: CGPoint, event: NSEvent) {
        var end = p
        if event.modifierFlags.contains(.shift) { end = Geometry.snapPoint(p, from: c.origin) }
        let candidates = scene.elements(canvas.spatialIndex.query(CGRect(center: p, size: CGSize(width: 40, height: 40))))
        let target = event.modifierFlags.contains(.command) ? nil
            : BindingSolver.target(at: end, in: scene, candidates: candidates, excluding: Set([c.id] + (c.startBinding.map { [$0.elementID] } ?? [])), tolerance: tolerance)
        bindingHighlight = target?.0.id
        scene.batch {
            scene.update(c.id) { e in
                e.setLinearWorldPoints([c.origin, end])
                if var d = e.linear {
                    d.startBinding = c.startBinding
                    d.endBinding = target.map { ConnectorBinding(elementID: $0.0.id, anchor: $0.1) }
                    e.linear = d
                }
            }
            if let e = scene.element(c.id), let solved = BindingSolver.solve(e, lookup: scene.element) { scene.replace(solved) }
        }
    }

    private func appendFreehand(_ f: inout FreehandState, _ raw: CGPoint, _ event: NSEvent) {
        guard let last = f.points.last else { return }
        // Streamline: low-pass filter the pointer for a calmer line.
        let p = last.lerp(to: raw, 0.6)
        let dist = p.distance(to: last)
        guard dist >= editor.viewport.worldLength(0.75) else { return }
        let dt = max(0.001, event.timestamp - f.lastTime)
        f.lastTime = event.timestamp
        let pressure: Double
        if f.hasRealPressure || (event.subtype == .tabletPoint && event.pressure > 0) {
            f.hasRealPressure = true
            pressure = Double(event.pressure)
        } else {
            // Simulate pressure from speed (screen points per second): faster strokes are thinner.
            let speed = Double(dist * editor.viewport.zoom / dt)
            let target = max(0.15, min(0.85, 0.85 - speed / 3000))
            pressure = (f.pressures.last ?? 0.5) * 0.7 + target * 0.3
        }
        f.points.append(p)
        f.pressures.append(pressure)
        let pts = f.points
        let prs = f.pressures
        scene.update(f.id) { e in
            guard let box = CGRect.bounding(pts) else { return }
            e.frame = box
            e.kind = .freehand(FreehandData(points: pts.map { $0 - box.origin }, pressures: prs))
        }
    }

    private func moveEndpoint(_ ep: EndpointState, to p: CGPoint, event: NSEvent) {
        guard let current = scene.element(ep.id), var d = current.linear else { return }
        var pts = current.worldPoints
        guard pts.count >= 2 else { return }
        let otherIndex = ep.isStart ? pts.count - 1 : 0
        var q = p
        if event.modifierFlags.contains(.shift) { q = Geometry.snapPoint(p, from: pts[otherIndex]) }
        let candidates = scene.elements(canvas.spatialIndex.query(CGRect(center: p, size: CGSize(width: 40, height: 40))))
        let otherBound = ep.isStart ? d.endBinding?.elementID : d.startBinding?.elementID
        let target = event.modifierFlags.contains(.command) ? nil
            : BindingSolver.target(at: q, in: scene, candidates: candidates, excluding: Set([ep.id] + (otherBound.map { [$0] } ?? [])), tolerance: tolerance)
        bindingHighlight = target?.0.id
        pts[ep.isStart ? 0 : pts.count - 1] = q
        let binding = target.map { ConnectorBinding(elementID: $0.0.id, anchor: $0.1) }
        if ep.isStart { d.startBinding = binding } else { d.endBinding = binding }
        scene.batch {
            scene.update(ep.id) { e in
                e.setLinearWorldPoints(pts)
                e.linear = LinearData(points: e.linear?.points ?? d.points, startBinding: d.startBinding, endBinding: d.endBinding)
            }
            if let e = scene.element(ep.id), let solved = BindingSolver.solve(e, lookup: scene.element) { scene.replace(solved) }
        }
    }

    private func erase(at p: CGPoint) {
        guard case var .erasing(ids) = state else { return }
        if let hit = hitTest(p, includeLocked: false) {
            ids.formUnion(SceneOps.expandToGroups([hit.id], in: scene))
        }
        state = .erasing(ids)
        canvas.needsDisplay = true
    }

    // MARK: Mouse up

    func mouseUp(_ event: NSEvent) {
        let finished = state
        state = .idle
        bindingHighlight = nil
        editor.snapGuides = []
        defer {
            canvas.needsDisplay = true
            canvas.updateCursor()
        }
        switch finished {
        case .idle, .panning:
            break
        case let .pressingSelection(press):
            if let narrow = press.narrowTo { editor.select(narrow) }
        case let .dragging(d):
            SceneOps.updateFrameMembership(d.ids, in: scene)
            editor.commands.endInteractive()
        case let .resizing(r):
            if r.started { editor.commands.endInteractive() }
        case let .rotating(r):
            if r.started { editor.commands.endInteractive() }
        case .marquee:
            break
        case let .creatingShape(c):
            guard let e = scene.element(c.id) else { editor.commands.cancelInteractive(); return }
            let screenSize = CGSize(width: e.frame.width * editor.viewport.zoom, height: e.frame.height * editor.viewport.zoom)
            if screenSize.width < 4 && screenSize.height < 4 {
                // A plain click with a shape tool drops a default-sized shape.
                let size: CGFloat = e.isFrame ? 320 : 100
                scene.update(c.id) { $0.frame = CGRect(center: c.origin, size: CGSize(width: size, height: e.isFrame ? 240 : size)) }
            }
            if e.isFrame { SceneOps.adoptContents(of: c.id, in: scene) } else { SceneOps.updateFrameMembership([c.id], in: scene) }
            editor.commands.endInteractive(selectionAfter: [c.id])
            finishTool()
        case let .creatingLinear(c):
            guard let e = scene.element(c.id) else { editor.commands.cancelInteractive(); return }
            let pts = e.worldPoints
            let len = (pts.first ?? .zero).distance(to: pts.last ?? .zero) * editor.viewport.zoom
            if len < 4 {
                editor.commands.cancelInteractive()
                return
            }
            SceneOps.updateFrameMembership([c.id], in: scene)
            editor.commands.endInteractive(selectionAfter: [c.id])
            finishTool()
        case let .drawingFreehand(f):
            NSEvent.isMouseCoalescingEnabled = true
            finishFreehand(f)
        case let .draggingEndpoint(ep):
            if ep.started { editor.commands.endInteractive() }
        case let .erasing(ids):
            if !ids.isEmpty { editor.perform(DeleteElementsCommand(name: "Erase", ids: ids)) }
        }
    }

    private func finishFreehand(_ f: FreehandState) {
        let keep = PathSmoothing.simplifyIndices(f.points, epsilon: editor.viewport.worldLength(0.35))
        let pts = keep.map { f.points[$0] }
        let prs = keep.map { f.pressures[$0] }
        scene.update(f.id) { e in
            guard let box = CGRect.bounding(pts) else { return }
            e.frame = box
            e.kind = .freehand(FreehandData(points: pts.map { $0 - box.origin }, pressures: prs))
        }
        SceneOps.updateFrameMembership([f.id], in: scene)
        editor.commands.endInteractive()
    }

    private func finishTool() {
        if !editor.toolLocked { editor.tool = .select }
    }

    /// Aborts the current gesture, reverting any live changes.
    func cancel() {
        let s = state
        state = .idle
        bindingHighlight = nil
        editor.snapGuides = []
        NSEvent.isMouseCoalescingEnabled = true
        switch s {
        case .dragging, .creatingShape, .creatingLinear, .drawingFreehand:
            editor.commands.cancelInteractive()
        case let .resizing(r) where r.started:
            editor.commands.cancelInteractive()
        case let .rotating(r) where r.started:
            editor.commands.cancelInteractive()
        case let .draggingEndpoint(ep) where ep.started:
            editor.commands.cancelInteractive()
        default:
            break
        }
        canvas.needsDisplay = true
        canvas.updateCursor()
    }

    // MARK: Hover / cursor

    func cursor(at s: CGPoint, flags: NSEvent.ModifierFlags) -> NSCursor {
        switch state {
        case .panning: return .closedHand
        case .dragging: return .arrow
        case let .resizing(r): return Cursors.resize(r.handle, rotation: r.originals.count == 1 ? r.originals[0].rotation : 0)
        case .rotating: return Cursors.rotate
        default: break
        }
        if canvas.isSpaceHeld { return .openHand }
        if editor.tool == .select {
            let overlay = SelectionOverlay(editor: editor)
            if let h = overlay.handle(at: s) {
                switch h {
                case .rotation: return Cursors.rotate
                case .lineStart, .lineEnd: return .crosshair
                default:
                    let rot = editor.selection.count == 1 ? (editor.selectedElements.first?.rotation ?? 0) : 0
                    return Cursors.resize(h, rotation: rot)
                }
            }
            return .arrow
        }
        if editor.tool == .text {
            return .iBeam
        }
        return editor.tool.cursor
    }

    func hoverElement(at s: CGPoint) -> ElementID? {
        guard editor.tool == .select, !isActive else { return nil }
        let p = editor.viewport.toWorld(s)
        guard let hit = hitTest(p) else { return nil }
        return editor.selection.contains(hit.id) ? nil : hit.id
    }
}
