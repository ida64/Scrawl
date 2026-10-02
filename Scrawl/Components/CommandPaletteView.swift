import SwiftUI

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let category: String
    let symbol: String
    var shortcut: String? = nil
    var keywords: String = ""
    let run: () -> Void
}

enum PaletteCommands {
    static func all(editor: Editor, canvas: CanvasView) -> [PaletteCommand] {
        let wc = canvas.window?.windowController as? DocumentWindowController
        var list: [PaletteCommand] = []
        func add(_ title: String, _ category: String, _ symbol: String, _ shortcut: String? = nil, keywords: String = "", _ run: @escaping () -> Void) {
            list.append(PaletteCommand(title: title, category: category, symbol: symbol, shortcut: shortcut, keywords: keywords, run: run))
        }

        // Tools
        for tool in Tool.toolbarOrder {
            add(tool.title, "Tool", tool.symbol, String(tool.shortcut).uppercased(), keywords: "tool draw") { editor.tool = tool }
        }

        // Insert
        add("Insert Rectangle", "Insert", "rectangle", keywords: "shape box") { editor.insertShape(.rectangle) }
        add("Insert Ellipse", "Insert", "circle", keywords: "shape oval circle") { editor.insertShape(.ellipse) }
        add("Insert Diamond", "Insert", "diamond", keywords: "shape decision") { editor.insertShape(.diamond) }
        add("Insert Frame", "Insert", "square.dashed", keywords: "artboard") { editor.insertShape(.frame) }
        add("Insert Text", "Insert", "textformat", "⌥⌘T") { editor.addText(at: editor.visibleCenter) }
        add("Insert Image…", "Insert", "photo", "⇧⌘I", keywords: "picture photo") { canvas.chooseImage(at: editor.visibleCenter) }

        // File & export
        add("New Drawing", "File", "doc.badge.plus", "⌘N") { NSDocumentController.shared.newDocument(nil) }
        add("Open…", "File", "folder", "⌘O") { NSDocumentController.shared.openDocument(nil) }
        add("Export…", "File", "square.and.arrow.up", "⇧⌘E", keywords: "png jpeg pdf svg save image") { editor.exportRequest = .drawing }
        for f in ExportFormat.allCases {
            add("Export as \(f.title)…", "File", "square.and.arrow.up", keywords: "export \(f.rawValue)") {
                Preferences.shared.lastExportFormat = f
                editor.exportRequest = .drawing
            }
        }
        add("Copy as PNG", "File", "photo.on.rectangle", "⇧⌘C", keywords: "clipboard image") { wc?.copyAsPNG(nil) }

        // View
        add("Zoom to Fit", "View", "arrow.up.left.and.down.right.magnifyingglass", "⌘1", keywords: "fit drawing") { editor.zoomToFit() }
        add("Zoom to Selection", "View", "viewfinder", "⌘2") { editor.zoomToSelection() }
        add("Zoom to 100%", "View", "1.magnifyingglass", "⌘0", keywords: "actual size") { editor.zoomToActualSize() }
        add(editor.gridStyle == .none ? "Show Grid" : "Hide Grid", "View", "circle.grid.3x3", "⌘'", keywords: "toggle grid") {
            editor.gridStyle = editor.gridStyle == .none ? .dots : .none
        }
        add("Dot Grid", "View", "circle.grid.3x3", keywords: "grid") { editor.gridStyle = .dots }
        add("Square Grid", "View", "grid", keywords: "grid lines") { editor.gridStyle = .lines }
        add(editor.snapEnabled ? "Turn Snapping Off" : "Turn Snapping On", "View", "dot.squareshape.split.2x2", "⇧⌘;", keywords: "toggle snap") { editor.toggleSnapping() }
        add(editor.inspectorVisible ? "Hide Inspector" : "Show Inspector", "View", "sidebar.right", "⌥⌘I", keywords: "toggle") { editor.toggleInspector() }
        add(editor.sidebarVisible ? "Hide Layers" : "Show Layers", "View", "sidebar.left", "⌃⌘S", keywords: "sidebar toggle layers frames") { editor.toggleSidebar() }
        add(editor.minimapVisible ? "Hide Minimap" : "Show Minimap", "View", "map", "⌥⌘M", keywords: "toggle") { editor.minimapVisible.toggle() }
        add("Focus Mode", "View", "viewfinder", "⇧⌘F", keywords: "presentation distraction") { editor.toggleFocusMode() }
        for f in editor.frames {
            add("Go to \(f.name)", "Frame", "square.dashed", keywords: "zoom frame artboard") { editor.zoomToFrame(f.id) }
        }

        // Appearance
        for mode in AppearanceMode.allCases {
            add("\(mode.title) Appearance", "App", mode == .dark ? "moon" : mode == .light ? "sun.max" : "circle.lefthalf.filled",
                keywords: "theme dark mode light mode appearance") { Preferences.shared.appearance = mode }
        }
        add("Keyboard Shortcuts", "Help", "keyboard", "⌘/", keywords: "help keys") { editor.shortcutsVisible = true }
        add("Settings…", "App", "gearshape", "⌘,", keywords: "preferences") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
        add("Open Sample Drawing", "Help", "sparkles", keywords: "tour demo") { NSApp.sendAction(#selector(AppDelegate.openSampleDrawing(_:)), to: nil, from: nil) }

        // Selection
        add("Select All", "Edit", "checkmark.rectangle.stack", "⌘A") { editor.selectAll() }
        for (i, mode) in RenderStyle.allCases.enumerated() {
            add("\(mode.title) Style", "Format", mode.symbol, "⌃⌘\(i + 1)", keywords: "render mode sketch hand drawn clean") { editor.setRenderStyle(mode) }
        }
        if !editor.selection.isEmpty {
            add("Duplicate", "Edit", "plus.square.on.square", "⌘D") { editor.duplicate() }
            add("Delete", "Edit", "trash", "⌫", keywords: "remove") { editor.deleteSelection() }
            add("Copy Style", "Format", "paintbrush", "⌥⌘C") { editor.copyStyle() }
            if editor.canPasteStyle { add("Paste Style", "Format", "paintbrush.pointed", "⌥⌘V") { editor.pasteStyle() } }
            add(editor.summary.allLocked ? "Unlock" : "Lock", "Arrange", "lock", "⇧⌘L") { editor.toggleLock() }
            add(editor.summary.allHidden ? "Show" : "Hide", "Arrange", "eye.slash", "⇧⌘H") { editor.toggleHiddenSelection() }
            for a in ReorderAction.allCases {
                add(a.title, "Arrange", "square.3.layers.3d", keywords: "layer order z") { editor.reorder(a) }
            }
            add("Export Selection…", "File", "square.and.arrow.up.on.square", "⌥⌘E") { wc?.exportSelection(nil) }
            add("Frame Selection", "Arrange", "square.dashed", "⌥⌘F", keywords: "wrap artboard") { editor.frameSelection() }
            add("Flip Horizontal", "Arrange", "arrow.left.and.right", "⇧⌥H", keywords: "mirror") { editor.flip(horizontal: true) }
            add("Flip Vertical", "Arrange", "arrow.up.and.down", "⇧⌥V", keywords: "mirror") { editor.flip(horizontal: false) }
            add("Rotate 90° Right", "Arrange", "rotate.right", "⌥⌘R") { editor.rotateSelection(by: .pi / 2) }
            for t in [ElementType.rectangle, .ellipse, .diamond, .line, .arrow] {
                add("Convert to \(t.displayName)", "Format", Editor.symbol(for: t), keywords: "change shape type") { editor.convert(to: t) }
            }
            if editor.selection.count > 1 {
                add("Group", "Arrange", "square.on.square.dashed", "⌘G") { editor.group() }
                for a in AlignAction.allCases { add(a.title, "Arrange", a.symbol, keywords: "align distribute") { editor.align(a) } }
            }
            if editor.summary.hasGroup { add("Ungroup", "Arrange", "square.on.square", "⇧⌘G") { editor.ungroup() } }
        }
        return list
    }

    /// Word-aware fuzzy match: every query word must match (as a subsequence) somewhere in the
    /// text; word starts and contiguous runs score higher.
    static func score(_ query: String, _ text: String) -> Int? {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return 0 }
        var total = 0
        for w in words {
            guard let s = subsequenceScore(Array(w), Array(text.lowercased())) else { return nil }
            total += s
        }
        return total - text.count / 12
    }

    private static func subsequenceScore(_ q: [Character], _ t: [Character]) -> Int? {
        var score = 0, qi = 0, last = -2
        for (i, c) in t.enumerated() where qi < q.count && c == q[qi] {
            score += 1
            if i == last + 1 { score += 3 }
            if i == 0 || t[i - 1] == " " || t[i - 1] == ":" { score += 6 }
            last = i
            qi += 1
        }
        return qi == q.count ? score : nil
    }
}

struct CommandPaletteView: View {
    let editor: Editor
    let canvas: CanvasView
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var results: [PaletteCommand] {
        let all = PaletteCommands.all(editor: editor, canvas: canvas)
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Without a query, lead with the most useful verbs rather than every tool.
            let preferred = ["Export…", "Zoom to Fit", "Insert Text", "Insert Frame", "Show Grid", "Hide Grid", "Show Layers", "Hide Layers", "Focus Mode", "Keyboard Shortcuts"]
            let top = preferred.compactMap { p in all.first { $0.title == p } }
            return top + all.filter { c in !top.contains { $0.id == c.id } }
        }
        return all.compactMap { c -> (PaletteCommand, Int)? in
            let a = PaletteCommands.score(query, c.title)
            let b = PaletteCommands.score(query, c.title + " " + c.keywords + " " + c.category).map { $0 - 6 }
            guard let s = [a, b].compactMap({ $0 }).max() else { return nil }
            return (c, s)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ScrawlTheme.accent)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(0, items.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .accessibilityLabel("Search commands")
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(ScrawlTheme.tertiaryText)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(ScrawlTheme.border))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            Rectangle().fill(ScrawlTheme.separator).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                            PaletteRow(command: c, highlighted: i == highlighted)
                                .id(i)
                                .onTapGesture { highlighted = i; run(items) }
                                .onHover { if $0 { highlighted = i } }
                        }
                        if items.isEmpty {
                            Text("No matching commands").font(.system(size: 12)).foregroundStyle(ScrawlTheme.secondaryText).padding(18)
                        }
                    }
                    .padding(5)
                }
                .frame(height: min(CGFloat(max(items.count, 1)) * 30 + 10, 330))
                .onChange(of: highlighted) { _, h in proxy.scrollTo(h) }
            }
        }
        .frame(width: 500)
        .elevatedSurface(radius: 12)
        .onAppear { focused = true; highlighted = 0 }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func run(_ items: [PaletteCommand]) {
        guard highlighted < items.count else { return }
        let c = items[highlighted]
        close()
        DispatchQueue.main.async { c.run() }
    }

    private func close() {
        editor.commandPaletteVisible = false
        editor.focusCanvas?()
    }
}

private struct PaletteRow: View {
    let command: PaletteCommand
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(highlighted ? Color.white : ScrawlTheme.secondaryText)
            Text(command.title)
                .font(.system(size: 13))
                .foregroundStyle(highlighted ? Color.white : ScrawlTheme.primaryText)
            Spacer()
            Text(command.category)
                .font(.system(size: 10.5))
                .foregroundStyle(highlighted ? Color.white.opacity(0.75) : ScrawlTheme.tertiaryText)
            if let k = command.shortcut {
                Text(k)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.9) : ScrawlTheme.secondaryText)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? ScrawlTheme.accent : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
