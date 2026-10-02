import AppKit

/// Workspace-level operations used by the inspector, layers sidebar, menus and palette.
extension Editor {
    // MARK: Layers

    /// Whether a scene change affects what the layers sidebar shows.
    func layersAffected(by change: SceneChange) -> Bool {
        if change.structural || change.reset {
            layerSignatures = Dictionary(uniqueKeysWithValues: scene.elements.map { ($0.id, Editor.layerSignature($0)) })
            return true
        }
        var affected = false
        for id in change.changedIDs {
            guard let e = scene.element(id) else { continue }
            let sig = Editor.layerSignature(e)
            if layerSignatures[id] != sig {
                layerSignatures[id] = sig
                affected = true
            }
        }
        return affected
    }

    static func layerSignature(_ e: Element) -> String {
        "\(e.displayName)|\(e.isHidden)|\(e.isLocked)|\(e.frameID?.uuidString ?? "")|\(e.groupIDs.last?.uuidString ?? "")"
    }

    func rename(_ id: ElementID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let e = scene.element(id) else { return }
        if e.isFrame {
            renameFrame(id, to: trimmed.isEmpty ? "Frame" : trimmed)
            return
        }
        let newName: String? = trimmed.isEmpty ? nil : trimmed
        guard e.name != newName else { return }
        perform(SimpleCommand(name: "Rename") { scene in
            scene.update(id) { $0.name = newName }
            return nil
        })
    }

    func setHidden(_ ids: Set<ElementID>, hidden: Bool) {
        guard !ids.isEmpty else { return }
        perform(SimpleCommand(name: hidden ? "Hide" : "Show") { scene in
            for id in SceneOps.expandFrames(ids, in: scene) { scene.update(id) { $0.isHidden = hidden } }
            return nil
        })
        if hidden { select(selection.subtracting(ids)) }
    }

    func setLocked(_ ids: Set<ElementID>, locked: Bool) {
        guard !ids.isEmpty else { return }
        perform(LockElementsCommand(ids: ids, lock: locked))
    }

    func toggleHiddenSelection() {
        guard !selection.isEmpty else { return }
        setHidden(selection, hidden: !summary.allHidden)
    }

    func showAllHidden() {
        let hidden = Set(scene.elements.filter(\.isHidden).map(\.id))
        guard !hidden.isEmpty else { return }
        setHidden(hidden, hidden: false)
    }

    /// Moves `ids` so they sit directly above `target` (or at the very back when nil).
    func moveLayers(_ ids: [ElementID], above target: ElementID?) {
        let moving = Set(ids)
        var order = scene.elements.map(\.id).filter { !moving.contains($0) }
        let block = scene.elements.map(\.id).filter(moving.contains)
        let at = target.flatMap { t in order.firstIndex(of: t).map { $0 + 1 } } ?? 0
        order.insert(contentsOf: block, at: min(at, order.count))
        guard order != scene.elements.map(\.id) else { return }
        perform(SimpleCommand(name: "Reorder") { scene in
            scene.setOrder(order)
            return nil
        })
    }

    // MARK: Geometry editing

    /// Sets position and/or size of the selection from the inspector (one undo step).
    func setGeometry(x: CGFloat? = nil, y: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil, keepAspect: Bool = false) {
        let ids = editableSelection
        let els = scene.elements(ids)
        guard !els.isEmpty, let box = els.count == 1 ? els[0].frame : CGRect.union(els.map(\.bounds)) else { return }
        var target = box
        if let x { target.origin.x = x }
        if let y { target.origin.y = y }
        if var w = width {
            w = max(1, w)
            if keepAspect, box.width > 0 { target.size.height = max(1, box.height * w / box.width) }
            target.size.width = w
        }
        if var h = height {
            h = max(1, h)
            if keepAspect, box.height > 0 { target.size.width = max(1, box.width * h / box.height) }
            target.size.height = h
        }
        guard target != box else { return }
        let name = (width != nil || height != nil) ? "Resize" : "Move"
        perform(SimpleCommand(name: name) { scene in
            if els.count == 1, let e = els.first {
                var n = e
                if target.size != e.frame.size {
                    n.resize(to: CGRect(origin: e.frame.origin, size: target.size))
                    if n.isText {
                        if case var .text(t) = n.kind { t.autoWidth = false; n.kind = .text(t) }
                        TextLayout.fit(&n)
                    }
                }
                n.frame.origin = target.origin
                if n.isLinear { n.setLinearWorldPoints(n.worldPoints) }
                scene.replace(n)
            } else {
                TransformMath.scale(els, from: box, to: target, in: scene)
            }
            BindingSolver.updateConnectors(in: scene, affectedBy: ids)
            SceneOps.updateFrameMembership(ids, in: scene)
            return nil
        })
    }

    func setRotation(degrees: CGFloat) {
        guard selection.count == 1, let e = selectedElements.first, !e.isLocked, !e.isFrame, !e.isLinear else { return }
        let target = Geometry.normalizeAngle(degrees * .pi / 180)
        rotateSelection(by: target - e.rotation)
    }

    // MARK: Colors

    func noteRecentColor(_ c: DrawingColor) {
        guard case .rgba = c else { return }
        var list = recentColors.filter { $0 != c }
        list.insert(c, at: 0)
        recentColors = Array(list.prefix(6))
        Preferences.shared.recentColors = recentColors
    }

    // MARK: Style clipboard

    nonisolated(unsafe) private static var copiedStyle: ElementStyle?

    func copyStyle() {
        guard let e = selectedElements.first else { return }
        Editor.copiedStyle = e.style
        showToast("Style copied", symbol: "paintbrush")
    }

    var canPasteStyle: Bool { Editor.copiedStyle != nil && !selection.isEmpty }

    func pasteStyle() {
        guard let style = Editor.copiedStyle, !editableSelection.isEmpty else { return }
        applyStyle("Paste Style") { s in
            // Keep text metrics of the target when pasting from a shape, and vice versa.
            s.strokeColor = style.strokeColor
            s.fillColor = style.fillColor
            s.fillStyle = style.fillStyle
            s.strokeWidth = style.strokeWidth
            s.strokeStyle = style.strokeStyle
            s.opacity = style.opacity
            s.renderStyle = style.renderStyle
            s.cornerRadius = style.cornerRadius
            s.fontFamily = style.fontFamily
            s.fontName = style.fontName
            s.fontWeight = style.fontWeight
        }
    }

    // MARK: Conversion

    func convert(to type: ElementType) {
        let ids = editableSelection.filter { id in
            guard let e = scene.element(id) else { return false }
            switch type {
            case .rectangle, .ellipse, .diamond: return [.rectangle, .ellipse, .diamond].contains(e.type) && e.type != type
            case .line, .arrow: return e.isLinear && e.type != type
            default: return false
            }
        }
        guard !ids.isEmpty else { return }
        perform(SimpleCommand(name: "Convert to \(type.displayName)") { scene in
            for id in ids {
                scene.update(id) { e in
                    switch type {
                    case .rectangle: e.kind = .rectangle
                    case .ellipse: e.kind = .ellipse
                    case .diamond: e.kind = .diamond
                    case .line:
                        if let d = e.linear { e.kind = .line(d) }
                    case .arrow:
                        if let d = e.linear {
                            e.kind = .arrow(d)
                            if e.style.endArrowhead == .none && e.style.startArrowhead == .none { e.style.endArrowhead = .triangle }
                        }
                    default: break
                    }
                }
            }
            BindingSolver.updateConnectors(in: scene, affectedBy: ids)
            return nil
        })
    }

    // MARK: Frames

    /// Wraps the selection in a new frame.
    func frameSelection() {
        let ids = selection.filter { scene.element($0)?.isFrame == false }
        guard let box = SceneOps.selectionBounds(ids, in: scene) else { return }
        let frame = makeElement(.frame, frame: box.expanded(by: 32))
        perform(SimpleCommand(name: "Frame Selection") { scene in
            scene.insert([frame], at: 0)
            for id in ids { scene.update(id) { $0.frameID = frame.id } }
            return [frame.id]
        })
        showToast("Framed \(ids.count) object\(ids.count == 1 ? "" : "s")", symbol: "square.dashed")
    }

    // MARK: Render mode

    func setRenderStyle(_ mode: RenderStyle) {
        applyStyle("\(mode.title) Style") { $0.renderStyle = mode }
        showToast("\(mode.title) style", symbol: mode.symbol)
    }

    // MARK: Chrome

    func toggleInspector() { setInspectorVisible?(!inspectorVisible) }
    func toggleSidebar() { setSidebarVisible?(!sidebarVisible) }
    func toggleFocusMode() { setFocusMode?(!focusMode) }
}

extension RenderStyle {
    var symbol: String {
        switch self {
        case .precision: return "square.on.circle"
        case .ink: return "scribble.variable"
        case .soft: return "cloud"
        }
    }

    var subtitle: String {
        switch self {
        case .precision: return "Crisp geometry for diagrams"
        case .ink: return "Hand-drawn, deterministic strokes"
        case .soft: return "Rounded, relaxed whiteboard look"
        }
    }
}
