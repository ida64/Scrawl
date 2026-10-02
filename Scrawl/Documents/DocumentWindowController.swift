import AppKit
import SwiftUI

/// One window per document: layers sidebar | tool rail + canvas + status strip | inspector,
/// under a unified toolbar. Owns that window's `Editor` and implements menu actions so they
/// work whatever control currently has focus.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate,
                                      NSSharingServicePickerToolbarItemDelegate {
    let editor: Editor
    let canvas: CanvasView
    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    private var observations: [NSKeyValueObservation] = []
    private var restorableStateTimer: Timer?
    private var preFocusState: (sidebar: Bool, inspector: Bool)?

    init(document: ScrawlDocument) {
        editor = Editor(scene: document.scene, assets: document.assets, undoManager: document.undoManager)
        canvas = CanvasView(editor: editor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 720, height: 460)
        window.isRestorable = true
        window.tabbingMode = .preferred
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbarStyle = .unified
        super.init(window: window)
        editor.document = document
        window.delegate = self
        shouldCascadeWindows = true
        buildSplitView()
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1360, height: 860))
        let toolbar = NSToolbar(identifier: "ScrawlToolbar.v2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.center()
        wireEditor()
        // The split view restores its autosaved layout; mirror it into the editor.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.editor.sidebarVisible = !self.sidebarItem.isCollapsed
            self.editor.inspectorVisible = !self.inspectorItem.isCollapsed
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    private func hosting<V: View>(_ view: V) -> NSHostingController<V> {
        let c = NSHostingController(rootView: view)
        c.sizingOptions = []
        return c
    }

    private func buildSplitView() {
        let sidebarVC = hosting(LayersSidebar(editor: editor))
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 340
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !editor.sidebarVisible

        let workspaceVC = hosting(WorkspaceView(editor: editor, canvas: canvas))
        let content = NSSplitViewItem(viewController: workspaceVC)
        content.minimumThickness = 360

        let inspectorVC = hosting(InspectorPanel(editor: editor))
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorVC)
        inspectorItem.minimumThickness = 264
        inspectorItem.maximumThickness = 360
        inspectorItem.canCollapse = true
        inspectorItem.isCollapsed = !editor.inspectorVisible

        split.splitViewItems = [sidebarItem, content, inspectorItem]
        split.splitView.autosaveName = "ScrawlDocumentSplit"

        // Keep the editor's flags in sync with native collapse (menus, toolbar, gestures).
        observations.append(sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated { self?.editor.sidebarVisible = !item.isCollapsed }
        })
        observations.append(inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            MainActor.assumeIsolated {
                self?.editor.inspectorVisible = !item.isCollapsed
                self?.scheduleRestorableStateUpdate()
            }
        })
    }

    private func wireEditor() {
        editor.viewportDidChangeExternal = { [weak self] in self?.scheduleRestorableStateUpdate() }
        editor.setInspectorVisible = { [weak self] visible in self?.setCollapsed(self?.inspectorItem, !visible) }
        editor.setSidebarVisible = { [weak self] visible in self?.setCollapsed(self?.sidebarItem, !visible) }
        editor.setFocusMode = { [weak self] on in self?.setFocusMode(on) }
        editor.showFontPanel = { [weak self] in self?.showFonts(nil) }
    }

    private func setCollapsed(_ item: NSSplitViewItem?, _ collapsed: Bool) {
        guard let item, item.isCollapsed != collapsed else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            item.isCollapsed = collapsed
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                item.animator().isCollapsed = collapsed
            }
        }
    }

    func setFocusMode(_ on: Bool) {
        guard on != editor.focusMode else { return }
        if on {
            // Focus mode is temporary: keep it out of the autosaved toolbar and split layout.
            window?.toolbar?.autosavesConfiguration = false
            split.splitView.autosaveName = nil
            preFocusState = (!sidebarItem.isCollapsed, !inspectorItem.isCollapsed)
            setCollapsed(sidebarItem, true)
            setCollapsed(inspectorItem, true)
            window?.toolbar?.isVisible = false
            editor.focusMode = true
            editor.commandPaletteVisible = false
        } else {
            window?.toolbar?.isVisible = true
            if let s = preFocusState {
                setCollapsed(sidebarItem, !s.sidebar)
                setCollapsed(inspectorItem, !s.inspector)
            }
            editor.focusMode = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.window?.toolbar?.autosavesConfiguration = true
                self?.split.splitView.autosaveName = "ScrawlDocumentSplit"
            }
        }
        window?.makeFirstResponder(canvas)
    }

    // MARK: Toolbar

    private enum ToolbarID {
        static let tool = NSToolbarItem.Identifier("scrawl.tool")
        static let palette = NSToolbarItem.Identifier("scrawl.palette")
        static let focus = NSToolbarItem.Identifier("scrawl.focus")
        static let share = NSToolbarItem.Identifier("scrawl.share")
        static let more = NSToolbarItem.Identifier("scrawl.more")
        static let style = NSToolbarItem.Identifier("scrawl.style")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
         ToolbarID.palette, ToolbarID.focus, ToolbarID.share, ToolbarID.more, .inspectorTrackingSeparator, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [ToolbarID.tool, ToolbarID.style, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolbarID.tool:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = NSHostingView(rootView: ToolbarToolIndicator(editor: editor))
            item.label = "Tool"
            item.paletteLabel = "Current Tool"
            item.toolTip = "Current tool — click to switch"
            item.visibilityPriority = .high
            return item
        case ToolbarID.style:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = NSHostingView(rootView: ToolbarStyleIndicator(editor: editor))
            item.label = "Style"
            item.paletteLabel = "Drawing Style"
            return item
        case ToolbarID.palette:
            return button(id, "Commands", "command", "Command Palette (⌘K)", #selector(showCommandPalette(_:)))
        case ToolbarID.focus:
            return button(id, "Focus", "viewfinder", "Focus Mode — hide all chrome (⇧⌘F)", #selector(toggleFocusMode(_:)))
        case ToolbarID.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: id)
            item.delegate = self
            item.label = "Share"
            item.toolTip = "Share a PNG of this drawing"
            return item
        case ToolbarID.more:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
            item.label = "More"
            item.toolTip = "Export and more"
            item.showsIndicator = false
            let menu = NSMenu()
            menu.addItem(withTitle: "Export…", action: #selector(exportDrawing(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Export Selection…", action: #selector(exportSelection(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy as PNG", action: #selector(copyAsPNG(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Show Minimap", action: #selector(toggleMinimap(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Keyboard Shortcuts", action: #selector(showShortcuts(_:)), keyEquivalent: "")
            item.menu = menu
            return item
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ tip: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = self
        item.isBordered = true
        return item
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        guard editor.hasContent,
              let data = ExportService.export(.drawing, format: .png, scene: editor.scene, assets: editor.assets, options: exportOptions(transparent: false)) else { return [] }
        let name = (document?.displayName ?? "Drawing") + ".png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) } catch { return [] }
        return [url]
    }

    // MARK: Window delegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if window?.firstResponder === window { window?.makeFirstResponder(canvas) }
    }

    // MARK: Restoration (viewport is restored per window, never saved into the document)

    private func scheduleRestorableStateUpdate() {
        restorableStateTimer?.invalidate()
        restorableStateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.window?.invalidateRestorableState() }
        }
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        let v = editor.viewport
        state.encode(Double(v.origin.x), forKey: "viewportX")
        state.encode(Double(v.origin.y), forKey: "viewportY")
        state.encode(Double(v.zoom), forKey: "viewportZoom")
        state.encode(editor.minimapVisible, forKey: "minimap")
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        let z = state.decodeDouble(forKey: "viewportZoom")
        if z > 0 {
            let v = CanvasViewport(origin: CGPoint(x: state.decodeDouble(forKey: "viewportX"), y: state.decodeDouble(forKey: "viewportY")),
                                   zoom: CanvasViewport.clampZoom(z))
            canvas.restoreViewport(v)
        }
        if state.containsValue(forKey: "minimap") { editor.minimapVisible = state.decodeBool(forKey: "minimap") }
    }

    // MARK: Fonts

    @objc func showFonts(_ sender: Any?) {
        let style = editor.summary.style
        NSFontManager.shared.target = self
        NSFontManager.shared.setSelectedFont(style.font(), isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(sender)
    }

    /// Sent by the Fonts panel.
    @objc func changeFont(_ sender: NSFontManager?) {
        let manager = sender ?? NSFontManager.shared
        let current = editor.summary.style.font()
        let font = manager.convert(current)
        editor.applyStyleCoalesced { s in
            s.fontName = font.fontName
            s.fontSize = Double(font.pointSize)
            s.fontWeight = .regular
        }
    }

    @objc func toggleBold(_ sender: Any?) {
        let bold = editor.summary.style.fontWeight != .bold
        editor.applyStyle("Bold") { $0.fontWeight = bold ? .bold : .regular }
    }

    @objc func biggerText(_ sender: Any?) { editor.applyStyle("Font Size") { $0.fontSize = min(400, ($0.fontSize * 1.15).rounded()) } }
    @objc func smallerText(_ sender: Any?) { editor.applyStyle("Font Size") { $0.fontSize = max(4, ($0.fontSize / 1.15).rounded()) } }

    @objc func alignTextAction(_ sender: NSMenuItem) {
        let all = TextAlign.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        editor.applyStyle("Text Alignment") { $0.textAlign = all[sender.tag] }
    }

    @objc func setRenderStyleAction(_ sender: NSMenuItem) {
        let all = RenderStyle.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        editor.setRenderStyle(all[sender.tag])
    }

    @objc func copyStyle(_ sender: Any?) { editor.copyStyle() }
    @objc func pasteStyle(_ sender: Any?) { editor.pasteStyle() }
    @objc func convertAction(_ sender: NSMenuItem) {
        let types: [ElementType] = [.rectangle, .ellipse, .diamond, .line, .arrow]
        guard sender.tag >= 0, sender.tag < types.count else { return }
        editor.convert(to: types[sender.tag])
    }
    @objc func frameSelection(_ sender: Any?) { editor.frameSelection() }
    @objc func toggleHidden(_ sender: Any?) { editor.toggleHiddenSelection() }
    @objc func showAllHidden(_ sender: Any?) { editor.showAllHidden() }
    @objc func toggleFocusMode(_ sender: Any?) { setFocusMode(!editor.focusMode) }
    @objc func toggleStatusBar(_ sender: Any?) { editor.statusBarVisible.toggle() }

    // MARK: Edit menu

    private var canvasIsEditingText: Bool { editor.editingTextID != nil }

    @objc func copy(_ sender: Any?) { editor.copy() }
    @objc func cut(_ sender: Any?) { editor.cut() }
    @objc func paste(_ sender: Any?) { editor.paste() }
    @objc func delete(_ sender: Any?) { editor.deleteSelection() }
    @objc override func selectAll(_ sender: Any?) { editor.selectAll() }
    @objc func duplicate(_ sender: Any?) { editor.duplicate() }
    @objc func copyAsPNG(_ sender: Any?) {
        guard let data = ExportService.export(editor.selection.isEmpty ? .drawing : .selection(editor.selection), format: .png,
                                              scene: editor.scene, assets: editor.assets, options: exportOptions(transparent: true)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: .png)
        editor.showToast("Copied as PNG", symbol: "photo.on.rectangle")
    }

    // MARK: Arrange menu

    @objc func group(_ sender: Any?) { editor.group() }
    @objc func ungroup(_ sender: Any?) { editor.ungroup() }
    @objc func bringForward(_ sender: Any?) { editor.reorder(.bringForward) }
    @objc func sendBackward(_ sender: Any?) { editor.reorder(.sendBackward) }
    @objc func bringToFront(_ sender: Any?) { editor.reorder(.bringToFront) }
    @objc func sendToBack(_ sender: Any?) { editor.reorder(.sendToBack) }
    @objc func alignAction(_ sender: NSMenuItem) {
        let all = AlignAction.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        editor.align(all[sender.tag])
    }
    @objc func toggleLock(_ sender: Any?) { editor.toggleLock() }
    @objc func rotateClockwise(_ sender: Any?) { editor.rotateSelection(by: .pi / 2) }
    @objc func rotateCounterclockwise(_ sender: Any?) { editor.rotateSelection(by: -.pi / 2) }
    @objc func flipHorizontal(_ sender: Any?) { editor.flip(horizontal: true) }
    @objc func flipVertical(_ sender: Any?) { editor.flip(horizontal: false) }

    // MARK: View menu

    @objc func zoomIn(_ sender: Any?) { editor.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { editor.zoomOut() }
    @objc func zoomToFit(_ sender: Any?) { editor.zoomToFit() }
    @objc func zoomToSelection(_ sender: Any?) { editor.zoomToSelection() }
    @objc func zoomToActualSize(_ sender: Any?) { editor.zoomToActualSize() }
    @objc func setGridStyle(_ sender: NSMenuItem) {
        let all = GridStyle.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        editor.gridStyle = all[sender.tag]
    }
    @objc func cycleGrid(_ sender: Any?) { editor.cycleGrid() }
    @objc func toggleSnapping(_ sender: Any?) { editor.toggleSnapping() }
    @objc func toggleMinimap(_ sender: Any?) { editor.minimapVisible.toggle() }
    @objc func showCommandPalette(_ sender: Any?) { editor.commandPaletteVisible.toggle() }
    @objc func showShortcuts(_ sender: Any?) { editor.shortcutsVisible.toggle() }
    @objc func selectToolAction(_ sender: NSMenuItem) {
        let all = Tool.toolbarOrder
        guard sender.tag >= 0, sender.tag < all.count else { return }
        editor.tool = all[sender.tag]
        window?.makeFirstResponder(canvas)
    }
    @objc func toggleToolLock(_ sender: Any?) { editor.toolLocked.toggle() }
    @objc func togglePerformanceHUD(_ sender: Any?) { editor.performanceHUD.toggle() }

    // MARK: Insert menu

    @objc func insertImage(_ sender: Any?) { canvas.chooseImage(at: editor.visibleCenter) }
    @objc func insertTextElement(_ sender: Any?) {
        window?.makeFirstResponder(canvas)
        canvas.interaction.createText(at: editor.visibleCenter, centered: true)
    }
    @objc func insertShape(_ sender: NSMenuItem) {
        let types: [ElementType] = [.rectangle, .ellipse, .diamond, .frame]
        guard sender.tag >= 0, sender.tag < types.count else { return }
        editor.insertShape(types[sender.tag])
    }

    // MARK: File menu

    @objc func exportDrawing(_ sender: Any?) { editor.exportRequest = .drawing }
    @objc func exportSelection(_ sender: Any?) {
        guard !editor.selection.isEmpty else { return }
        if editor.selection.count == 1, let id = editor.selection.first, editor.scene.element(id)?.isFrame == true {
            editor.exportRequest = .frame(id)
        } else {
            editor.exportRequest = .selection(editor.selection)
        }
    }

    func exportOptions(transparent: Bool) -> ExportOptions {
        var o = ExportOptions()
        o.dark = editor.isDarkCanvas
        o.transparentBackground = transparent
        o.background = editor.scene.settings.background
        o.scale = 2
        o.padding = 16
        return o
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasSelection = !editor.selection.isEmpty
        let editable = !editor.editableSelection.isEmpty
        switch item.action {
        case #selector(copy(_:)), #selector(duplicate(_:)):
            return hasSelection
        case #selector(cut(_:)), #selector(delete(_:)):
            return editable
        case #selector(paste(_:)):
            return true
        case #selector(copyAsPNG(_:)):
            return editor.hasContent
        case #selector(selectAll(_:)):
            return editor.hasContent
        case #selector(group(_:)):
            return editor.selection.count > 1
        case #selector(ungroup(_:)):
            return editor.summary.hasGroup
        case #selector(bringForward(_:)), #selector(sendBackward(_:)), #selector(bringToFront(_:)), #selector(sendToBack(_:)):
            return hasSelection
        case #selector(alignAction(_:)):
            let all = AlignAction.allCases
            guard item.tag >= 0, item.tag < all.count else { return false }
            return AlignCommand.units(editor.editableSelection, in: editor.scene).count >= all[item.tag].minimumCount
        case #selector(toggleLock(_:)):
            item.title = editor.summary.allLocked && hasSelection ? "Unlock" : "Lock"
            return hasSelection
        case #selector(rotateClockwise(_:)), #selector(rotateCounterclockwise(_:)), #selector(flipHorizontal(_:)), #selector(flipVertical(_:)):
            return editable
        case #selector(zoomToSelection(_:)):
            return hasSelection
        case #selector(setGridStyle(_:)):
            let all = GridStyle.allCases
            item.state = item.tag < all.count && all[item.tag] == editor.gridStyle ? .on : .off
            return true
        case #selector(toggleSnapping(_:)):
            item.state = editor.snapEnabled ? .on : .off
            return true
        case #selector(toggleFocusMode(_:)):
            item.state = editor.focusMode ? .on : .off
            return true
        case #selector(toggleStatusBar(_:)):
            item.title = editor.statusBarVisible ? "Hide Status Bar" : "Show Status Bar"
            return true
        case #selector(toggleBold(_:)), #selector(biggerText(_:)), #selector(smallerText(_:)), #selector(alignTextAction(_:)), #selector(showFonts(_:)):
            if item.action == #selector(alignTextAction(_:)) {
                let all = TextAlign.allCases
                item.state = editor.summary.hasText && item.tag < all.count && all[item.tag] == editor.summary.style.textAlign ? .on : .off
            }
            return editor.summary.hasText || editor.tool == .text
        case #selector(setRenderStyleAction(_:)):
            let all = RenderStyle.allCases
            item.state = item.tag < all.count && all[item.tag] == editor.summary.style.renderStyle ? .on : .off
            return true
        case #selector(copyStyle(_:)):
            return editor.selection.count == 1
        case #selector(pasteStyle(_:)):
            return editor.canPasteStyle
        case #selector(convertAction(_:)):
            let types: [ElementType] = [.rectangle, .ellipse, .diamond, .line, .arrow]
            guard item.tag < types.count else { return false }
            let target = types[item.tag]
            let shapes: Set<ElementType> = [.rectangle, .ellipse, .diamond], lines: Set<ElementType> = [.line, .arrow]
            let pool = shapes.contains(target) ? shapes : lines
            return !editor.summary.types.isEmpty && editor.summary.types.isSubset(of: pool) && editor.summary.types != [target]
        case #selector(frameSelection(_:)):
            return hasSelection && !editor.summary.types.contains(.frame)
        case #selector(toggleHidden(_:)):
            item.title = editor.summary.allHidden && hasSelection ? "Show" : "Hide"
            return hasSelection
        case #selector(showAllHidden(_:)):
            return editor.scene.elements.contains(where: \.isHidden)
        case #selector(toggleMinimap(_:)):
            item.title = editor.minimapVisible ? "Hide Minimap" : "Show Minimap"
            return true
        case #selector(selectToolAction(_:)):
            let all = Tool.toolbarOrder
            item.state = item.tag < all.count && all[item.tag] == editor.tool ? .on : .off
            return true
        case #selector(toggleToolLock(_:)):
            item.state = editor.toolLocked ? .on : .off
            return true
        case #selector(exportDrawing(_:)):
            return editor.hasContent
        case #selector(exportSelection(_:)):
            return hasSelection
        default:
            return responds(to: item.action)
        }
    }
}
