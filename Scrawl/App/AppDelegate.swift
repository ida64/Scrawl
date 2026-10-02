import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var welcome: WelcomeWindowController?
    private var settings: NSWindowController?
    private var isTerminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        Preferences.shared.applyAppearance()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(closing) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // UI tests launch with a fresh untitled drawing regardless of preferences.
        if ProcessInfo.processInfo.arguments.contains("-UITestFreshDrawing") {
            NSDocumentController.shared.newDocument(nil)
            return
        }
        if isHostingUnitTests { return }
        #if DEBUG
        if let demo = UserDefaults.standard.string(forKey: "ScrawlDemo") {
            DispatchQueue.main.async { self.runDemo(demo) }
            return
        }
        #endif
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty && Preferences.shared.launchBehavior == .welcome {
                self.showWelcome(nil)
            }
        }
    }

    /// True when the app is only hosting unit tests.
    private var isHostingUnitTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !isHostingUnitTests && Preferences.shared.launchBehavior == .newDrawing
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        // If termination gets cancelled (e.g. by a save sheet), behave normally again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.isTerminating = false }
        return .terminateNow
    }

    private func windowWillClose(_ window: NSWindow?) {
        guard let window, window.windowController is DocumentWindowController else { return }
        // When the last drawing closes (and we're not quitting), offer the welcome window.
        DispatchQueue.main.async {
            let remaining = NSApp.windows.contains { $0.isVisible && $0.windowController is DocumentWindowController }
            if !remaining && !self.isTerminating { self.showWelcome(nil) }
        }
    }

    // MARK: Actions

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil { welcome = WelcomeWindowController() }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
    }

    func closeWelcome() {
        welcome?.close()
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isRestorable = false
            window.center()
            settings = NSWindowController(window: window)
        }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openSampleDrawing(_ sender: Any?) {
        let (drawing, assets) = SampleDocument.make()
        openUntitled(drawing, assets: assets, name: "Scrawl Tour")
    }

    func openUntitled(_ drawing: Drawing, assets: AssetStore, name: String?) {
        do {
            guard let doc = try NSDocumentController.shared.makeUntitledDocument(ofType: UTType.scrawlDrawing.identifier) as? ScrawlDocument else { return }
            doc.assets.merge(assets)
            doc.scene.load(drawing)
            if let name { doc.displayName = name }
            NSDocumentController.shared.addDocument(doc)
            doc.makeWindowControllers()
            doc.showWindows()
            closeWelcome()
        } catch {
            NSApp.presentError(error)
        }
    }

    #if DEBUG
    /// Debug-only: sets up a UI state for visual review (`-ScrawlDemo <state>`).
    private func runDemo(_ state: String) {
        for d in NSDocumentController.shared.documents { d.close() }
        if state == "empty" {
            NSDocumentController.shared.newDocument(nil)
            return
        }
        if state == "welcome" {
            showWelcome(nil)
            return
        }
        let (drawing, assets) = SampleDocument.make()
        openUntitled(drawing, assets: assets, name: "Scrawl Tour")
        guard let doc = NSDocumentController.shared.documents.last as? ScrawlDocument, let editor = doc.editor else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let byName = { (n: String) in editor.scene.elements.first { $0.displayName == n }?.id }
            switch state {
            case "single":
                if let label = editor.scene.elements.first(where: { $0.displayName == "API" }),
                   let shape = editor.scene.elements.first(where: { $0.type == .rectangle && $0.frame.contains(label.center) }) {
                    editor.select([shape.id])
                }
            case "multi":
                editor.select(Set(editor.scene.elements.filter { $0.type == .rectangle && $0.frameID != nil }.prefix(3).map(\.id)))
            case "text":
                if let id = byName("Scrawl") { editor.select([id]) }
            case "arrow":
                if let a = editor.scene.elements.first(where: { $0.type == .arrow }) { editor.select([a.id]) }
            case "frame":
                if let f = editor.scene.elements.first(where: \.isFrame) { editor.select([f.id]) }
            case "sidebar":
                editor.setSidebarVisible?(true)
                if let id = byName("Database") { editor.select([id]) }
            case "palette":
                editor.commandPaletteVisible = true
            case "focus":
                editor.toggleFocusMode()
            default:
                break
            }
        }
    }

    @objc func generateBenchmark(_ sender: NSMenuItem) {
        openUntitled(SyntheticScenes.make(count: sender.tag), assets: AssetStore(), name: "Benchmark \(sender.tag)")
    }
    #endif
}
