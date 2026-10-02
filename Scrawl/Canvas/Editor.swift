import AppKit
import Observation

/// What the inspector needs to know about the current selection.
struct SelectionSummary: Equatable {
    var count = 0
    var types: Set<ElementType> = []
    var style = ElementStyle()
    var anyLocked = false
    var allLocked = false
    var hasGroup = false
    var frameID: ElementID?
    var frameName: String?
    var bounds: CGRect?
    var rotation: CGFloat = 0
    var textAutoWidth = true
    /// Editable geometry: the element frame for one element, the shared bounds otherwise.
    var geometry: CGRect?
    var allHidden = false
    var singleType: ElementType?

    var isEmpty: Bool { count == 0 }
    var hasShapes: Bool { !types.isDisjoint(with: [.rectangle, .ellipse, .diamond]) }
    var hasLinear: Bool { !types.isDisjoint(with: [.line, .arrow]) }
    var hasArrow: Bool { types.contains(.arrow) }
    var hasText: Bool { types.contains(.text) }
    var hasStroke: Bool { !types.isDisjoint(with: [.rectangle, .ellipse, .diamond, .line, .arrow, .freehand]) }
    var hasCornerRadius: Bool { !types.isDisjoint(with: [.rectangle, .diamond, .image]) }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var symbol: String?
}

/// Per-window editing session: owns the selection, tool, viewport and current style, and exposes
/// every user action. The document owns the scene and assets; the editor never holds global state.
@Observable
final class Editor {
    @ObservationIgnored let scene: Scene
    @ObservationIgnored let assets: AssetStore
    @ObservationIgnored let commands: CommandManager
    @ObservationIgnored weak var document: NSDocument?

    // MARK: Observable UI state

    var tool: Tool = .select { didSet { if oldValue != tool { toolDidChange?() } } }
    var toolLocked = false
    private(set) var selection: Set<ElementID> = []
    private(set) var summary = SelectionSummary()
    /// Style used for new elements; edits with an empty selection change this.
    var currentStyle: ElementStyle
    private(set) var zoom: CGFloat = 1
    var inspectorVisible = true
    var minimapVisible: Bool
    var commandPaletteVisible = false
    var shortcutsVisible = false
    var performanceHUD = false
    /// Hides all chrome so only the canvas remains.
    var focusMode = false
    var sidebarVisible = false
    var statusBarVisible = true
    /// Bumped when anything shown in the layers sidebar changes (names, order, visibility…).
    private(set) var layersRevision = 0
    var recentColors: [DrawingColor] = Preferences.shared.recentColors
    var exportRequest: ExportScope?
    var toast: Toast?
    var gridStyle: GridStyle { didSet { if oldValue != gridStyle { persistGrid() } } }
    var gridSpacing: Double { didSet { if oldValue != gridSpacing { persistGrid() } } }
    var snapEnabled: Bool
    private(set) var editingTextID: ElementID?
    /// Image currently in crop mode (resize handles crop instead of scaling).
    private(set) var croppingImageID: ElementID?
    private(set) var hasContent = false
    private(set) var frames: [FrameInfo] = []

    struct FrameInfo: Equatable, Identifiable {
        let id: ElementID
        let name: String
    }

    // MARK: Canvas-only state (not observed by SwiftUI)

    @ObservationIgnored var viewport = CanvasViewport() {
        didSet {
            if viewport.zoom != zoom { zoom = viewport.zoom }
            viewportDidChange?()
            viewportDidChangeExternal?()
            for o in viewportObservers.values { o() }
        }
    }
    @ObservationIgnored var viewportDidChangeExternal: (() -> Void)?
    /// Window-level layout requests (implemented by the window controller).
    @ObservationIgnored var setInspectorVisible: ((Bool) -> Void)?
    @ObservationIgnored var setSidebarVisible: ((Bool) -> Void)?
    @ObservationIgnored var setFocusMode: ((Bool) -> Void)?
    @ObservationIgnored var showFontPanel: (() -> Void)?
    /// Cached row descriptions used to detect sidebar-relevant changes cheaply.
    @ObservationIgnored var layerSignatures: [ElementID: String] = [:]
    @ObservationIgnored private var viewportObservers: [UUID: () -> Void] = [:]

    @discardableResult
    func observeViewport(_ handler: @escaping () -> Void) -> UUID {
        let t = UUID()
        viewportObservers[t] = handler
        return t
    }

    func removeViewportObserver(_ token: UUID) { viewportObservers[token] = nil }
    @ObservationIgnored var viewSize: CGSize = CGSize(width: 1000, height: 700)
    @ObservationIgnored var snapGuides: [SnapGuide] = []
    @ObservationIgnored var needsDisplay: (() -> Void)?
    @ObservationIgnored var viewportDidChange: (() -> Void)?
    @ObservationIgnored var toolDidChange: (() -> Void)?
    @ObservationIgnored var beginTextEditing: ((ElementID, Bool) -> Void)?
    @ObservationIgnored var focusCanvas: (() -> Void)?
    @ObservationIgnored var requestFrameRename: ((ElementID) -> Void)?
    @ObservationIgnored var requestTextCreation: ((CGPoint) -> Void)?
    @ObservationIgnored private var observerToken: UUID?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var lastDuplicate: (source: Set<ElementID>, copies: Set<ElementID>, offset: CGPoint)?
    @ObservationIgnored private var pasteCount = 0
    @ObservationIgnored private var lastPasteChangeCount = -1
    @ObservationIgnored private var viewportAnimation: Timer?

    init(scene: Scene, assets: AssetStore, undoManager: UndoManager?) {
        self.scene = scene
        self.assets = assets
        self.commands = CommandManager(scene: scene)
        let prefs = Preferences.shared
        currentStyle = prefs.defaultStyle
        minimapVisible = prefs.showMinimap
        gridStyle = scene.settings.grid
        gridSpacing = scene.settings.gridSpacing
        snapEnabled = prefs.snapToObjects
        commands.undoManager = undoManager
        commands.getSelection = { [unowned self] in self.selection }
        commands.setSelection = { [unowned self] in self.select($0) }
        observerToken = scene.observe { [weak self] change in self?.sceneDidChange(change) }
        refreshDerivedState()
    }

    deinit {
        // Scene is owned by the document and may outlive the editor.
        if let t = observerToken { MainActor.assumeIsolated { scene.removeObserver(t) } }
    }

    private func sceneDidChange(_ change: SceneChange) {
        if change.settings {
            if gridStyle != scene.settings.grid { gridStyle = scene.settings.grid }
            if gridSpacing != scene.settings.gridSpacing { gridSpacing = scene.settings.gridSpacing }
        }
        if !change.removedIDs.isEmpty || change.reset {
            let valid = selection.filter(scene.contains)
            if valid != selection { selection = valid }
        }
        if let id = editingTextID, !scene.contains(id) { editingTextID = nil }
        if layersAffected(by: change) { layersRevision &+= 1 }
        refreshDerivedState()
        needsDisplay?()
    }

    private func refreshDerivedState() {
        let s = makeSummary()
        if s != summary { summary = s }
        if hasContent != (scene.count > 0) { hasContent = scene.count > 0 }
        let f = scene.elements.compactMap { e in e.frameData.map { FrameInfo(id: e.id, name: $0.name) } }
        if f != frames { frames = f }
    }

    private func makeSummary() -> SelectionSummary {
        var s = SelectionSummary()
        let els = scene.elements(selection)
        guard let first = els.first else {
            s.style = currentStyle
            return s
        }
        s.count = els.count
        s.types = Set(els.map(\.type))
        // Prefer the style of a stroke-bearing element so the inspector shows meaningful values.
        s.style = (els.first { $0.type != .image && $0.type != .frame } ?? first).style
        s.anyLocked = els.contains(where: \.isLocked)
        s.allLocked = els.allSatisfy(\.isLocked)
        s.hasGroup = els.contains { !$0.groupIDs.isEmpty }
        if els.count == 1, let f = first.frameData { s.frameID = first.id; s.frameName = f.name }
        s.bounds = CGRect.union(els.map(\.bounds))
        s.rotation = els.count == 1 ? first.rotation : 0
        if let t = first.textData { s.textAutoWidth = t.autoWidth }
        s.geometry = els.count == 1 ? first.frame : s.bounds
        s.allHidden = els.allSatisfy(\.isHidden)
        s.singleType = s.types.count == 1 ? s.types.first : nil
        return s
    }

    // MARK: Selection

    var selectedElements: [Element] { scene.elements(selection) }

    func select(_ ids: Set<ElementID>) {
        guard ids != selection else { return }
        if let c = croppingImageID, ids != [c] { croppingImageID = nil }
        selection = ids
        refreshDerivedState()
        needsDisplay?()
    }

    func selectAll() {
        tool = .select
        select(Set(scene.elements.map(\.id)))
    }

    func clearSelection() { select([]) }

    // MARK: Viewport

    func setViewport(_ v: CanvasViewport, animated: Bool = false) {
        viewportAnimation?.invalidate()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else { viewport = v; return }
        let start = viewport
        let startTime = CACurrentMediaTime()
        let duration = 0.22
        viewportAnimation = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, (CACurrentMediaTime() - startTime) / duration)
                let e = CGFloat(1 - pow(1 - t, 3))
                // Interpolate zoom geometrically and the screen-center point linearly for a natural feel.
                let z = start.zoom * pow(v.zoom / start.zoom, e)
                let c0 = start.toWorld(CGPoint(x: self.viewSize.width / 2, y: self.viewSize.height / 2))
                let c1 = v.toWorld(CGPoint(x: self.viewSize.width / 2, y: self.viewSize.height / 2))
                var cur = CanvasViewport(origin: .zero, zoom: z)
                cur.center(on: c0.lerp(to: c1, e), viewSize: self.viewSize)
                self.viewport = t >= 1 ? v : cur
                if t >= 1 { timer.invalidate() }
            }
        }
    }

    func zoom(to z: CGFloat, animated: Bool = true) {
        var v = viewport
        v.zoom(to: z, anchor: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        setViewport(v, animated: animated)
    }

    func zoomIn() { zoom(to: CanvasViewport.nextStep(after: viewport.zoom)) }
    func zoomOut() { zoom(to: CanvasViewport.previousStep(before: viewport.zoom)) }
    func zoomToActualSize() { zoom(to: 1) }

    func zoomToFit() {
        guard let r = CGRect.union(scene.elements.map(\.bounds)) else {
            setViewport(CanvasViewport(origin: CGPoint(x: -viewSize.width / 2, y: -viewSize.height / 2), zoom: 1), animated: true)
            return
        }
        setViewport(.fitting(r, viewSize: viewSize), animated: true)
    }

    func zoomToSelection() {
        guard let r = summary.bounds else { zoomToFit(); return }
        setViewport(.fitting(r, viewSize: viewSize, maxZoom: 4), animated: true)
    }

    func zoomToFrame(_ id: ElementID) {
        guard let f = scene.element(id) else { return }
        select([id])
        setViewport(.fitting(f.frame.expanded(by: 20), viewSize: viewSize, padding: 48, maxZoom: 4), animated: true)
    }

    /// World point at the visible center (used for keyboard-driven insertions).
    var visibleCenter: CGPoint { viewport.toWorld(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)) }

    // MARK: Feedback

    func showToast(_ message: String, symbol: String? = nil) {
        toast = Toast(message: message, symbol: symbol)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Grid

    private func persistGrid() {
        var s = scene.settings
        s.grid = gridStyle
        s.gridSpacing = gridSpacing
        guard s != scene.settings else { return }
        // Grid is a view preference saved with the document but not part of undo history.
        scene.setSettings(s)
        document?.updateChangeCount(.changeDone)
        needsDisplay?()
    }

    func cycleGrid() {
        let all = GridStyle.allCases
        let next = all[(all.firstIndex(of: gridStyle).map { $0 + 1 } ?? 0) % all.count]
        gridStyle = next
        showToast(next == .none ? "Grid hidden" : "\(next.displayName) enabled", symbol: "grid")
    }

    func toggleSnapping() {
        snapEnabled.toggle()
        showToast(snapEnabled ? "Snapping on" : "Snapping off", symbol: "dot.squareshape.split.2x2")
    }

    // MARK: Element factory

    func makeElement(_ type: ElementType, frame: CGRect) -> Element {
        var style = currentStyle
        let kind: ElementKind
        switch type {
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .diamond: kind = .diamond
        case .line:
            kind = .line(LinearData(points: [.zero, CGPoint(x: frame.width, y: frame.height)]))
            style.startArrowhead = .none
            style.endArrowhead = .none
        case .arrow:
            kind = .arrow(LinearData(points: [.zero, CGPoint(x: frame.width, y: frame.height)]))
            if style.endArrowhead == .none && style.startArrowhead == .none { style.endArrowhead = .arrow }
        case .freehand: kind = .freehand(FreehandData(points: [], pressures: []))
        case .text: kind = .text(TextData(text: "", autoWidth: true))
        case .image: kind = .image(ImageData(assetID: "", crop: CGRect(x: 0, y: 0, width: 1, height: 1)))
        case .frame:
            kind = .frame(FrameData(name: "Frame \(scene.elements.filter(\.isFrame).count + 1)"))
            style.fillColor = .clear
        }
        if type == .image { style.cornerRadius = 0; style.strokeWidth = 0 }
        if type == .rectangle || type == .diamond { style.cornerRadius = currentStyle.cornerRadius } else if type != .image { style.cornerRadius = 0 }
        return Element(kind: kind, frame: frame, style: style)
    }

    // MARK: Commands

    @discardableResult
    func perform(_ command: SceneCommand) -> Bool { commands.perform(command) }

    /// The selection limited to elements that can be edited (not locked).
    var editableSelection: Set<ElementID> { SceneOps.unlocked(selection, in: scene) }

    func deleteSelection() {
        let ids = editableSelection
        guard !ids.isEmpty else {
            if !selection.isEmpty { showToast("Locked items can't be deleted", symbol: "lock") }
            return
        }
        perform(DeleteElementsCommand(ids: ids))
    }

    func nudge(_ delta: CGPoint) {
        let ids = editableSelection
        guard !ids.isEmpty else { return }
        perform(MoveElementsCommand(name: "Nudge", ids: ids, delta: delta))
    }

    func duplicate() {
        let ids = selection
        guard !ids.isEmpty else { return }
        var offset = CGPoint(x: 16, y: 16)
        // Smart duplication: if the last duplicate was moved, repeat that offset.
        if let last = lastDuplicate, last.copies == ids,
           let src = SceneOps.selectionBounds(last.source, in: scene), let cur = SceneOps.selectionBounds(ids, in: scene) {
            offset = CGPoint(x: cur.minX - src.minX, y: cur.minY - src.minY)
        }
        let source = scene.elements(SceneOps.expandFrames(ids, in: scene))
        var newIDs: [ElementID] = []
        perform(SimpleCommand(name: "Duplicate") { scene in
            newIDs = SceneOps.insertCopies(of: source, offset: offset, in: scene)
            return Set(newIDs)
        })
        lastDuplicate = (ids, Set(newIDs), offset)
        showToast("Duplicated", symbol: "plus.square.on.square")
    }

    func group() {
        guard selection.count > 1 else { return }
        perform(GroupElementsCommand(ids: selection))
        showToast("Grouped", symbol: "square.on.square.dashed")
    }

    func ungroup() {
        guard summary.hasGroup else { return }
        perform(UngroupElementsCommand(ids: selection))
        showToast("Ungrouped", symbol: "square.on.square")
    }

    func reorder(_ action: ReorderAction) {
        guard !selection.isEmpty else { return }
        perform(ReorderCommand(ids: selection, action: action))
    }

    func align(_ action: AlignAction) {
        perform(AlignCommand(ids: selection, action: action))
    }

    func toggleLock() {
        guard !selection.isEmpty else { return }
        let lock = !summary.allLocked
        perform(LockElementsCommand(ids: selection, lock: lock))
        showToast(lock ? "Locked" : "Unlocked", symbol: lock ? "lock" : "lock.open")
    }

    func flip(horizontal: Bool) {
        let ids = editableSelection
        guard let box = SceneOps.selectionBounds(ids, in: scene) else { return }
        let originals = scene.elements(ids)
        let target = horizontal
            ? CGRect(x: box.maxX, y: box.minY, width: -box.width, height: box.height)
            : CGRect(x: box.minX, y: box.maxY, width: box.width, height: -box.height)
        perform(SimpleCommand(name: horizontal ? "Flip Horizontal" : "Flip Vertical") { scene in
            TransformMath.scale(originals, from: box, to: target, in: scene)
            BindingSolver.updateConnectors(in: scene, affectedBy: ids)
            return nil
        })
    }

    /// Inserts a default-sized shape at the center of the view (keyboard / menu / palette flow).
    func insertShape(_ type: ElementType) {
        let size = type == .frame ? CGSize(width: 480, height: 320) : CGSize(width: 160, height: type == .ellipse || type == .diamond ? 120 : 100)
        let e = makeElement(type, frame: CGRect(center: visibleCenter, size: size))
        perform(CreateElementsCommand(name: "Add \(type.displayName)", elements: [e]))
        tool = .select
    }

    func rotateSelection(by angle: CGFloat) {
        guard !editableSelection.isEmpty else { return }
        perform(RotateElementsCommand(ids: editableSelection, angle: angle))
    }

    // MARK: Style

    @ObservationIgnored private var scrubSerial = -1
    private var scrubbing: Bool { commands.isInteracting && commands.interactiveSerial == scrubSerial }

    /// Applies a style change to the selection (as one undo step) and to the default style.
    func applyStyle(_ name: String = "Change Style", _ change: @escaping (inout ElementStyle) -> Void) {
        change(&currentStyle)
        let ids = selection
        guard !ids.isEmpty else { refreshDerivedState(); return }
        if scrubbing {
            scene.batch {
                for id in ids { scene.update(id) { change(&$0.style) } }
                SceneOps.refitText(ids, in: scene)
                BindingSolver.updateConnectors(in: scene, affectedBy: ids)
            }
        } else {
            perform(ChangeStyleCommand(name: name, ids: ids, change: change))
        }
    }

    /// Continuous edits (slider drags) are coalesced into one undo step.
    func beginStyleScrub() {
        guard !scrubbing, !selection.isEmpty else { return }
        commands.beginInteractive("Change Style")
        scrubSerial = commands.interactiveSerial
    }

    func endStyleScrub() {
        coalesceTimer?.invalidate()
        guard scrubbing else { return }
        scrubSerial = -1
        commands.endInteractive()
    }

    @ObservationIgnored private var coalesceTimer: Timer?

    /// For continuous pickers without begin/end callbacks (the system color panel): changes
    /// within a short window become one undo step.
    func applyStyleCoalesced(_ change: @escaping (inout ElementStyle) -> Void) {
        if !scrubbing { beginStyleScrub() }
        applyStyle("Change Style", change)
        coalesceTimer?.invalidate()
        coalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endStyleScrub() }
        }
    }

    func setTextAutoWidth(_ auto: Bool) {
        let ids = selection.filter { scene.element($0)?.isText == true }
        guard !ids.isEmpty else { return }
        perform(SimpleCommand(name: "Text Width") { scene in
            for id in ids {
                scene.update(id) {
                    guard case var .text(t) = $0.kind else { return }
                    t.autoWidth = auto
                    $0.kind = .text(t)
                    TextLayout.fit(&$0)
                }
            }
            return nil
        })
    }

    func renameFrame(_ id: ElementID, to name: String) {
        guard scene.element(id)?.frameData?.name != name else { return }
        perform(RenameFrameCommand(id: id, newName: name))
    }

    // MARK: Cropping

    func beginCrop(_ id: ElementID) {
        guard let e = scene.element(id), e.type == .image, !e.isLocked else { return }
        select([id])
        croppingImageID = id
        showToast("Drag handles to crop · Return to finish", symbol: "crop")
        needsDisplay?()
    }

    func endCrop() {
        guard croppingImageID != nil else { return }
        croppingImageID = nil
        needsDisplay?()
    }

    func resetCrop() {
        let ids = selection.filter { scene.element($0)?.type == .image }
        guard !ids.isEmpty else { return }
        perform(SimpleCommand(name: "Reset Crop") { scene in
            for id in ids {
                guard let e = scene.element(id), let full = TransformMath.uncroppedRect(e), case var .image(img) = e.kind else { continue }
                img.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                scene.update(id) {
                    $0.kind = .image(img)
                    $0.frame = TransformMath.place(full, unrotatedAround: e.center, rotation: e.rotation)
                }
            }
            return nil
        })
    }

    // MARK: Text editing

    func startEditingText(_ id: ElementID, isNew: Bool) {
        editingTextID = id
        beginTextEditing?(id, isNew)
    }

    /// Creates a new text element at a world point and starts editing it.
    func addText(at world: CGPoint) {
        requestTextCreation?(world)
    }

    func didEndEditingText() {
        editingTextID = nil
        needsDisplay?()
    }

    // MARK: Images

    /// Inserts images centered at a world point, laid out side by side.
    @discardableResult
    func insertImages(_ items: [(data: Data, ext: String?)], at world: CGPoint) -> Bool {
        var elements: [Element] = []
        var x = world.x
        for item in items {
            guard let id = assets.add(data: item.data, fileExtension: item.ext), let natural = assets.naturalSize(id) else { continue }
            // Fit large images to a comfortable on-screen size.
            let maxSide = max(160, min(720, 640 / max(viewport.zoom, 0.1)))
            let scale = min(1, maxSide / max(natural.width, natural.height, 1))
            let size = CGSize(width: max(8, natural.width * scale), height: max(8, natural.height * scale))
            var e = makeElement(.image, frame: CGRect(x: x, y: world.y - size.height / 2, width: size.width, height: size.height))
            e.kind = .image(ImageData(assetID: id, crop: CGRect(x: 0, y: 0, width: 1, height: 1)))
            elements.append(e)
            x += size.width + 24
        }
        guard !elements.isEmpty else {
            showToast("Couldn't read that image", symbol: "exclamationmark.triangle")
            return false
        }
        // Center the whole row on the drop point.
        let totalWidth = x - 24 - world.x
        let shift = CGPoint(x: -totalWidth / 2, y: 0)
        elements = elements.map { var e = $0; e.translate(by: shift); return e }
        perform(CreateElementsCommand(name: elements.count == 1 ? "Insert Image" : "Insert Images", elements: elements))
        tool = .select
        return true
    }

    func insertImages(from urls: [URL], at world: CGPoint) -> Bool {
        let items: [(data: Data, ext: String?)] = urls.compactMap { url in
            guard let d = try? Data(contentsOf: url) else { return nil }
            return (d, url.pathExtension.isEmpty ? nil : url.pathExtension)
        }
        return insertImages(items, at: world)
    }

    // MARK: Clipboard

    func copy() {
        guard !selection.isEmpty else { return }
        let ids = SceneOps.expandFrames(selection, in: scene)
        Clipboard.write(scene.elements(ids), assets: assets, dark: isDarkCanvas)
        showToast("Copied", symbol: "doc.on.doc")
    }

    func cut() {
        guard !editableSelection.isEmpty else { return }
        copy()
        perform(DeleteElementsCommand(name: "Cut", ids: editableSelection))
    }

    func paste(at world: CGPoint? = nil) {
        let pb = NSPasteboard.general
        if pb.changeCount != lastPasteChangeCount { pasteCount = 0; lastPasteChangeCount = pb.changeCount }
        pasteCount += 1
        switch Clipboard.read(pb) {
        case let .elements(elements, pastedAssets):
            assets.merge(pastedAssets)
            guard let box = CGRect.union(elements.map(\.bounds)) else { return }
            let offset: CGPoint
            if let world {
                offset = world - box.center
            } else {
                // Paste in place if visible (with a small cascading offset); otherwise at the view center.
                let visible = viewport.visibleWorldRect(viewSize: viewSize)
                let step = CGFloat(pasteCount) * 16
                offset = visible.intersects(box) ? CGPoint(x: step, y: step) : visibleCenter - box.center
            }
            var newIDs: [ElementID] = []
            perform(SimpleCommand(name: "Paste") { scene in
                newIDs = SceneOps.insertCopies(of: elements, offset: offset, in: scene)
                SceneOps.updateFrameMembership(Set(newIDs), in: scene)
                return Set(newIDs)
            })
            tool = .select
        case let .images(items):
            insertImages(items, at: world ?? visibleCenter)
        case let .text(string):
            insertText(string, at: world ?? visibleCenter)
        case .none:
            NSSound.beep()
        }
    }

    func insertText(_ string: String, at world: CGPoint) {
        var e = makeElement(.text, frame: CGRect(origin: world, size: .zero))
        e.kind = .text(TextData(text: string, autoWidth: true))
        TextLayout.fit(&e)
        if e.frame.width > 600 {
            e.kind = .text(TextData(text: string, autoWidth: false))
            e.frame.size.width = 600
            TextLayout.fit(&e)
        }
        e.frame.origin = world - CGPoint(x: e.frame.width / 2, y: e.frame.height / 2)
        perform(CreateElementsCommand(name: "Paste Text", elements: [e]))
        tool = .select
    }

    var isDarkCanvas: Bool {
        if let bg = scene.settings.background, case let .rgba(r, g, b, _) = bg {
            return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// A one-off command built from a closure.
struct SimpleCommand: SceneCommand {
    let name: String
    let body: (Scene) -> Set<ElementID>?

    init(name: String, _ body: @escaping (Scene) -> Set<ElementID>?) {
        self.name = name
        self.body = body
    }

    func execute(in scene: Scene) -> Set<ElementID>? { body(scene) }
}

enum ExportScope: Equatable, Identifiable {
    case drawing, selection(Set<ElementID>), frame(ElementID)
    var id: String {
        switch self {
        case .drawing: return "drawing"
        case .selection: return "selection"
        case let .frame(f): return "frame-\(f)"
        }
    }
}
