import AppKit

/// NSMenuItem that runs a closure (for context-specific items).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

enum ContextMenuBuilder {
    static func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], symbol: String? = nil, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.tag = tag
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    typealias WC = DocumentWindowController

    static func menu(for editor: Editor, at world: CGPoint) -> NSMenu {
        let m = NSMenu()
        if editor.selection.isEmpty {
            m.addItem(ClosureMenuItem("Paste Here", key: "v", modifiers: .command) { editor.paste(at: world) })
            m.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
            m.addItem(.separator())
            m.addItem(ClosureMenuItem("Add Text Here") { editor.focusCanvas?(); editor.addText(at: world) })
            m.addItem(item("Insert Image…", #selector(WC.insertImage(_:))))
            m.addItem(.separator())
            m.addItem(gridMenuItem())
            m.addItem(item("Zoom to Fit", #selector(WC.zoomToFit(_:)), "1"))
            if editor.scene.elements.contains(where: \.isHidden) {
                m.addItem(item("Show All Hidden", #selector(WC.showAllHidden(_:))))
            }
            return m
        }
        let s = editor.summary
        m.addItem(item("Cut", #selector(WC.cut(_:)), "x"))
        m.addItem(item("Copy", #selector(WC.copy(_:)), "c"))
        m.addItem(item("Duplicate", #selector(WC.duplicate(_:)), "d"))
        m.addItem(.separator())
        if s.count > 1 { m.addItem(item("Group", #selector(WC.group(_:)), "g")) }
        if s.hasGroup { m.addItem(item("Ungroup", #selector(WC.ungroup(_:)), "g", [.command, .shift])) }
        if !s.types.contains(.frame) { m.addItem(item("Frame Selection", #selector(WC.frameSelection(_:)), "f", [.command, .option])) }
        m.addItem(.separator())
        m.addItem(item("Bring to Front", #selector(WC.bringToFront(_:)), "]", [.command, .option]))
        m.addItem(item("Send to Back", #selector(WC.sendToBack(_:)), "[", [.command, .option]))
        m.addItem(arrangeMenuItem())
        if s.count > 1 { m.addItem(alignMenuItem()) }
        m.addItem(.separator())
        m.addItem(styleMenuItem(editor))
        if let convert = convertMenuItem(editor) { m.addItem(convert) }
        m.addItem(.separator())
        m.addItem(item(s.allLocked ? "Unlock" : "Lock", #selector(WC.toggleLock(_:)), "l", [.command, .shift]))
        m.addItem(item(s.allHidden ? "Show" : "Hide", #selector(WC.toggleHidden(_:)), "h", [.command, .shift]))
        if s.count == 1, let id = editor.selection.first {
            if s.types == [.frame] {
                m.addItem(ClosureMenuItem("Rename Frame…") { editor.requestFrameRename?(id) })
                m.addItem(ClosureMenuItem("Zoom to Frame") { editor.zoomToFrame(id) })
                m.addItem(ClosureMenuItem("Export Frame…") { editor.exportRequest = .frame(id) })
            } else if s.types == [.image] {
                m.addItem(ClosureMenuItem("Crop") { editor.beginCrop(id) })
            }
        }
        if s.types != [.frame] {
            m.addItem(item("Export Selection…", #selector(WC.exportSelection(_:)), "e", [.command, .option]))
        }
        m.addItem(.separator())
        m.addItem(item("Delete", #selector(WC.delete(_:))))
        return m
    }

    static func styleMenuItem(_ editor: Editor) -> NSMenuItem {
        let parent = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, mode) in RenderStyle.allCases.enumerated() {
            let it = item(mode.title, #selector(WC.setRenderStyleAction(_:)), "\(i + 1)", [.command, .control], tag: i)
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let strokes = NSMenuItem(title: "Stroke Color", action: nil, keyEquivalent: "")
        let strokeMenu = NSMenu()
        for c in Palette.stroke {
            let it = ClosureMenuItem(Palette.name(for: c)) { editor.applyStyle("Stroke") { $0.strokeColor = c } }
            it.image = swatchImage(c, dark: editor.isDarkCanvas)
            strokeMenu.addItem(it)
        }
        strokes.submenu = strokeMenu
        sub.addItem(strokes)
        let fills = NSMenuItem(title: "Fill", action: nil, keyEquivalent: "")
        let fillMenu = NSMenu()
        for c in Palette.fill {
            let it = ClosureMenuItem(Palette.name(for: c)) { editor.applyStyle("Fill") { $0.fillColor = c } }
            it.image = swatchImage(c, dark: editor.isDarkCanvas)
            fillMenu.addItem(it)
        }
        fills.submenu = fillMenu
        sub.addItem(fills)
        sub.addItem(.separator())
        sub.addItem(item("Copy Style", #selector(WC.copyStyle(_:)), "c", [.command, .option]))
        sub.addItem(item("Paste Style", #selector(WC.pasteStyle(_:)), "v", [.command, .option]))
        parent.submenu = sub
        return parent
    }

    static func convertMenuItem(_ editor: Editor) -> NSMenuItem? {
        let types = editor.summary.types
        let shapes: Set<ElementType> = [.rectangle, .ellipse, .diamond], lines: Set<ElementType> = [.line, .arrow]
        let options: [(String, Int)]
        if !types.isEmpty && types.isSubset(of: shapes) {
            options = [("Rectangle", 0), ("Ellipse", 1), ("Diamond", 2)]
        } else if !types.isEmpty && types.isSubset(of: lines) {
            options = [("Line", 3), ("Arrow", 4)]
        } else {
            return nil
        }
        let parent = NSMenuItem(title: "Convert To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, tag) in options { sub.addItem(item(title, #selector(WC.convertAction(_:)), tag: tag)) }
        parent.submenu = sub
        return parent
    }

    static func swatchImage(_ c: DrawingColor, dark: Bool) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if c.isClear {
                NSColor.secondaryLabelColor.setStroke()
                path.stroke()
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2, y: 2)); slash.line(to: NSPoint(x: 10, y: 10))
                NSColor.systemRed.setStroke()
                slash.stroke()
            } else {
                c.nsColor(dark: dark).setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.stroke()
            }
            return true
        }
    }

    static func arrangeMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
                let sub = NSMenu()
        sub.addItem(item("Bring to Front", #selector(DocumentWindowController.bringToFront(_:)), "]", [.command, .option]))
        sub.addItem(item("Bring Forward", #selector(DocumentWindowController.bringForward(_:)), "]"))
        sub.addItem(item("Send Backward", #selector(DocumentWindowController.sendBackward(_:)), "["))
        sub.addItem(item("Send to Back", #selector(DocumentWindowController.sendToBack(_:)), "[", [.command, .option]))
        parent.submenu = sub
        return parent
    }

    static func alignMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Align", action: nil, keyEquivalent: "")
                let sub = NSMenu()
        for (i, a) in AlignAction.allCases.enumerated() {
            if i == 3 || i == 6 { sub.addItem(.separator()) }
            sub.addItem(item(a.title, #selector(DocumentWindowController.alignAction(_:)), tag: i))
        }
        parent.submenu = sub
        return parent
    }

    static func gridMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Grid", action: nil, keyEquivalent: "")
                let sub = NSMenu()
        for (i, g) in GridStyle.allCases.enumerated() {
            sub.addItem(item(g.displayName, #selector(DocumentWindowController.setGridStyle(_:)), tag: i))
        }
        parent.submenu = sub
        return parent
    }
}
