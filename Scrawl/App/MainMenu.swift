import AppKit

/// Builds the main menu. Nearly every action in Scrawl is reachable here with its shortcut
/// visible; items target the responder chain so they reach the key window's controller.
enum MainMenu {
    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], tag: Int = 0, symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        i.tag = tag
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem], symbol: String? = nil) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    typealias WC = DocumentWindowController

    static func build() -> NSMenu {
        let main = NSMenu()

        // Scrawl
        let appMenu = NSMenu()
        appMenu.addItem(item("About Scrawl", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ","))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Scrawl", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Scrawl", #selector(NSApplication.terminate(_:)), "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File
        main.addItem(submenu("File", [
            item("New Drawing", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            submenu("Open Recent", [item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)))]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", #selector(NSDocument.save(_:)), "s"),
            item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            item("Rename…", #selector(NSDocument.rename(_:))),
            item("Move To…", #selector(NSDocument.move(_:))),
            item("Revert To Saved", #selector(NSDocument.revertToSaved(_:))),
            item("Browse All Versions…", #selector(NSDocument.browseVersions(_:))),
            .separator(),
            item("Import Image…", #selector(WC.insertImage(_:)), "i", [.command, .shift]),
            item("Export…", #selector(WC.exportDrawing(_:)), "e", [.command, .shift]),
            item("Export Selection…", #selector(WC.exportSelection(_:)), "e", [.command, .option]),
            item("Copy as PNG", #selector(WC.copyAsPNG(_:)), "c", [.command, .shift]),
            .separator(),
            item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ]))

        // Edit
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Duplicate", #selector(WC.duplicate(_:)), "d"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Style", #selector(WC.copyStyle(_:)), "c", [.command, .option]),
            item("Paste Style", #selector(WC.pasteStyle(_:)), "v", [.command, .option]),
        ]))

        // View
        let tools = Tool.toolbarOrder.enumerated().map { i, t in
            item(t.title, #selector(WC.selectToolAction(_:)), tag: i)
        }
        let grid = GridStyle.allCases.enumerated().map { i, g in item(g.displayName, #selector(WC.setGridStyle(_:)), tag: i) }
        main.addItem(submenu("View", [
            item("Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Show Inspector", #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option]),
            item("Hide Status Bar", #selector(WC.toggleStatusBar(_:)), "/", [.command, .option]),
            item("Focus Mode", #selector(WC.toggleFocusMode(_:)), "f", [.command, .shift]),
            .separator(),
            submenu("Tools", tools + [.separator(), item("Keep Tool Active", #selector(WC.toggleToolLock(_:)))]),
            item("Command Palette…", #selector(WC.showCommandPalette(_:)), "k"),
            .separator(),
            item("Zoom In", #selector(WC.zoomIn(_:)), "="),
            item("Zoom Out", #selector(WC.zoomOut(_:)), "-"),
            item("Actual Size", #selector(WC.zoomToActualSize(_:)), "0"),
            item("Zoom to Fit", #selector(WC.zoomToFit(_:)), "1"),
            item("Zoom to Selection", #selector(WC.zoomToSelection(_:)), "2"),
            .separator(),
            submenu("Grid", grid + [.separator(), item("Cycle Grid", #selector(WC.cycleGrid(_:)), "'")]),
            item("Snap to Objects", #selector(WC.toggleSnapping(_:)), ";", [.command, .shift]),
            item("Show Minimap", #selector(WC.toggleMinimap(_:)), "m", [.command, .option]),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        // Insert
        main.addItem(submenu("Insert", [
            item("Text", #selector(WC.insertTextElement(_:)), "t", [.command, .option]),
            item("Image…", #selector(WC.insertImage(_:)), "i", [.command, .shift]),
            .separator(),
            item("Rectangle", #selector(WC.insertShape(_:)), tag: 0),
            item("Ellipse", #selector(WC.insertShape(_:)), tag: 1),
            item("Diamond", #selector(WC.insertShape(_:)), tag: 2),
            item("Frame", #selector(WC.insertShape(_:)), tag: 3),
            .separator(),
            item("Frame Selection", #selector(WC.frameSelection(_:)), "f", [.command, .option]),
        ]))

        // Format
        let renderModes = RenderStyle.allCases.enumerated().map { i, m in
            item(m.title, #selector(WC.setRenderStyleAction(_:)), "\(i + 1)", [.command, .control], tag: i)
        }
        main.addItem(submenu("Format", [
            submenu("Style", renderModes),
            .separator(),
            submenu("Font", [
                item("Show Fonts", #selector(WC.showFonts(_:)), "t"),
                item("Bold", #selector(WC.toggleBold(_:)), "b"),
                .separator(),
                item("Bigger", #selector(WC.biggerText(_:)), "+", [.command, .shift]),
                item("Smaller", #selector(WC.smallerText(_:)), "-", [.command, .shift]),
                .separator(),
                item("Show Colors", #selector(NSApplication.orderFrontColorPanel(_:)), "c", [.command, .shift, .option]),
            ]),
            submenu("Text", [
                item("Align Left", #selector(WC.alignTextAction(_:)), "{", tag: 0),
                item("Center", #selector(WC.alignTextAction(_:)), "|", tag: 1),
                item("Align Right", #selector(WC.alignTextAction(_:)), "}", tag: 2),
            ]),
            .separator(),
            submenu("Convert To", [
                item("Rectangle", #selector(WC.convertAction(_:)), tag: 0),
                item("Ellipse", #selector(WC.convertAction(_:)), tag: 1),
                item("Diamond", #selector(WC.convertAction(_:)), tag: 2),
                .separator(),
                item("Line", #selector(WC.convertAction(_:)), tag: 3),
                item("Arrow", #selector(WC.convertAction(_:)), tag: 4),
            ]),
            .separator(),
            item("Copy Style", #selector(WC.copyStyle(_:)), "c", [.command, .option]),
            item("Paste Style", #selector(WC.pasteStyle(_:)), "v", [.command, .option]),
        ]))

        // Arrange
        let align = AlignAction.allCases.enumerated().flatMap { i, a -> [NSMenuItem] in
            let it = item(a.title, #selector(WC.alignAction(_:)), tag: i)
            return (i == 3 || i == 6) ? [.separator(), it] : [it]
        }
        main.addItem(submenu("Arrange", [
            item("Group", #selector(WC.group(_:)), "g"),
            item("Ungroup", #selector(WC.ungroup(_:)), "g", [.command, .shift]),
            .separator(),
            item("Bring to Front", #selector(WC.bringToFront(_:)), "]", [.command, .option]),
            item("Bring Forward", #selector(WC.bringForward(_:)), "]"),
            item("Send Backward", #selector(WC.sendBackward(_:)), "["),
            item("Send to Back", #selector(WC.sendToBack(_:)), "[", [.command, .option]),
            .separator(),
            submenu("Align & Distribute", align),
            .separator(),
            item("Rotate 90° Right", #selector(WC.rotateClockwise(_:)), "r", [.command, .option]),
            item("Rotate 90° Left", #selector(WC.rotateCounterclockwise(_:)), "r", [.command, .option, .shift]),
            item("Flip Horizontal", #selector(WC.flipHorizontal(_:)), "h", [.shift, .option]),
            item("Flip Vertical", #selector(WC.flipVertical(_:)), "v", [.shift, .option]),
            .separator(),
            item("Lock", #selector(WC.toggleLock(_:)), "l", [.command, .shift]),
            item("Hide", #selector(WC.toggleHidden(_:)), "h", [.command, .shift]),
            item("Show All Hidden", #selector(WC.showAllHidden(_:))),
        ]))

        // Window
        let windowMenuItem = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Welcome to Scrawl", #selector(AppDelegate.showWelcome(_:)), "0", [.command, .shift]),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenuItem.submenu
        main.addItem(windowMenuItem)

        // Help
        var helpItems: [NSMenuItem] = [
            item("Keyboard Shortcuts", #selector(WC.showShortcuts(_:)), "/"),
            item("Open Sample Drawing", #selector(AppDelegate.openSampleDrawing(_:))),
        ]
        #if DEBUG
        helpItems.append(.separator())
        helpItems.append(submenu("Developer", [1_000, 5_000, 10_000].map { n in
            item("Generate \(n.formatted()) Element Scene", #selector(AppDelegate.generateBenchmark(_:)), tag: n)
        } + [item("Toggle Performance HUD", #selector(WC.togglePerformanceHUD(_:)))]))
        #endif
        let helpMenuItem = submenu("Help", helpItems)
        NSApp.helpMenu = helpMenuItem.submenu
        main.addItem(helpMenuItem)
        return main
    }
}
