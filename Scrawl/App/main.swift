import AppKit

// The custom document controller must be created before anything touches
// NSDocumentController.shared, so it becomes the shared instance.
_ = ScrawlDocumentController()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
