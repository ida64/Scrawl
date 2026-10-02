import AppKit
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let scrawlDrawing = UTType(exportedAs: "app.scrawl.drawing", conformingTo: .package)
    nonisolated static let excalidraw = UTType(importedAs: "com.excalidraw.drawing", conformingTo: .json)
}

/// One open drawing. Owns the scene (document state) and its assets; each window controller
/// creates an `Editor` for per-window state (selection, viewport, tool).
final class ScrawlDocument: NSDocument {
    let scene = Scene()
    let assets = AssetStore()
    private var lastFileWrapper: FileWrapper?
    private var pendingWarnings: [String] = []
    private var sceneObserver: UUID?

    override init() {
        super.init()
        scene.load(Drawing(elements: [], settings: Preferences.shared.defaultSettings))
        hasUndoManager = true
    }

    nonisolated override class var autosavesInPlace: Bool {
        UserDefaults.standard.object(forKey: "autosave") as? Bool ?? true
    }

    nonisolated override class var readableTypes: [String] {
        [UTType.scrawlDrawing.identifier, UTType.excalidraw.identifier]
    }

    nonisolated override class var writableTypes: [String] { [UTType.scrawlDrawing.identifier] }

    nonisolated override class func isNativeType(_ type: String) -> Bool { type == UTType.scrawlDrawing.identifier }

    override func makeWindowControllers() {
        let wc = DocumentWindowController(document: self)
        addWindowController(wc)
        if !pendingWarnings.isEmpty, let window = wc.window {
            let warnings = pendingWarnings
            pendingWarnings = []
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Some of this drawing couldn’t be recovered"
                alert.informativeText = warnings.joined(separator: "\n") + "\n\nEverything that could be read has been opened. Saving will keep the recovered content."
                alert.beginSheetModal(for: window)
            }
        }
    }

    // MARK: Reading

    /// NSDocument reads on the main thread unless concurrent reading is enabled (it isn't), but
    /// the overridden methods are nonisolated, so hop explicitly if that ever changes.
    private nonisolated func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try MainActor.assumeIsolated { try body() } }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated { try body() } }
    }

    nonisolated override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        nonisolated(unsafe) let wrapper = fileWrapper
        try onMain { try self.load(from: wrapper, ofType: typeName) }
    }

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        try onMain { try self.load(from: data, ofType: typeName) }
    }

    private func load(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        if typeName == UTType.excalidraw.identifier, let data = fileWrapper.regularFileContents {
            try load(from: data, ofType: typeName)
            return
        }
        let decoded = try DocumentCodec.decode(fileWrapper)
        assets.merge(decoded.assets)
        scene.load(decoded.drawing)
        pendingWarnings = decoded.warnings
        lastFileWrapper = fileWrapper
    }

    func load(from data: Data, ofType typeName: String) throws {
        if typeName == UTType.excalidraw.identifier {
            let imported = try ExcalidrawImporter.importDrawing(data)
            assets.merge(imported.assets)
            scene.load(imported.drawing)
            pendingWarnings = imported.warnings
            return
        }
        try load(from: FileWrapper(regularFileWithContents: data), ofType: typeName)
    }

    // MARK: Writing

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let preview = ExportService.previewPNG(scene: scene, assets: assets, dark: dark)
        let wrapper = try DocumentCodec.fileWrapper(for: scene.drawing, assets: assets, preview: preview, reusing: lastFileWrapper)
        lastFileWrapper = wrapper
        return wrapper
    }

    // MARK: Printing

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        var o = ExportOptions()
        o.scale = 1
        o.background = .rgba(r: 1, g: 1, b: 1, a: 1)
        guard let data = ExportService.export(.drawing, format: .pdf, scene: scene, assets: assets, options: o),
              let pdf = NSPDFImageRep(data: data) else { throw DocumentError.missingContent }
        let view = NSImageView(frame: CGRect(origin: .zero, size: pdf.bounds.size))
        let image = NSImage(size: pdf.bounds.size)
        image.addRepresentation(pdf)
        view.image = image
        let op = NSPrintOperation(view: view, printInfo: printInfo)
        op.printInfo.horizontalPagination = .fit
        op.printInfo.verticalPagination = .fit
        return op
    }

    var editor: Editor? { (windowControllers.first as? DocumentWindowController)?.editor }
}

/// Opens Excalidraw files as new untitled drawings so the original JSON file is never overwritten.
final class ScrawlDocumentController: NSDocumentController {
    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        if typeName == UTType.excalidraw.identifier {
            guard let doc = try makeUntitledDocument(ofType: UTType.scrawlDrawing.identifier) as? ScrawlDocument else {
                throw DocumentError.notAScrawlDocument
            }
            let data = try Data(contentsOf: url)
            try doc.load(from: data, ofType: typeName)
            doc.displayName = url.deletingPathExtension().lastPathComponent
            doc.updateChangeCount(.changeDone)
            return doc
        }
        return try super.makeDocument(withContentsOf: url, ofType: typeName)
    }
}
