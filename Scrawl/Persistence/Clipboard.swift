import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    static let scrawlElements = NSPasteboard.PasteboardType("app.scrawl.elements")
}

/// Copy/paste of elements. Scrawl data round-trips as editable vectors; other apps get a PNG
/// rendering and the plain text of any text elements.
enum Clipboard {
    private struct Payload: Codable {
        var version = 1
        var elements: [PersistedElement]
        var assets: [EmbeddedAsset]
    }

    private struct EmbeddedAsset: Codable {
        var id: String
        var ext: String
        var data: Data
    }

    enum Content {
        case elements([Element], AssetStore)
        case images([(data: Data, ext: String?)])
        case text(String)
        case none
    }

    static func encode(_ elements: [Element], assets: AssetStore) -> Data? {
        let ids = Set(elements.compactMap { e -> String? in
            if case let .image(i) = e.kind { return i.assetID }
            return nil
        })
        let embedded = ids.sorted().compactMap { id in assets.asset(id).map { EmbeddedAsset(id: id, ext: $0.fileExtension, data: $0.data) } }
        return try? JSONEncoder().encode(Payload(elements: elements.map { PersistenceMapping.persist($0) }, assets: embedded))
    }

    static func decode(_ data: Data) -> ([Element], AssetStore)? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let store = AssetStore()
        for a in payload.assets { store.insert(.init(id: a.id, data: a.data, fileExtension: a.ext)) }
        let elements = payload.elements.compactMap { try? PersistenceMapping.element($0) }
        return elements.isEmpty ? nil : (elements, store)
    }

    static func write(_ elements: [Element], assets: AssetStore, dark: Bool, to pb: NSPasteboard = .general) {
        guard let data = encode(elements, assets: assets) else { return }
        pb.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.scrawlElements, .png]
        let texts = elements.compactMap { $0.textData?.text }.filter { !$0.isEmpty }
        if !texts.isEmpty { types.append(.string) }
        pb.declareTypes(types, owner: nil)
        pb.setData(data, forType: .scrawlElements)
        if !texts.isEmpty { pb.setString(texts.joined(separator: "\n"), forType: .string) }
        // Render a PNG for other apps (Keynote, Messages, …).
        let scene = Scene(drawing: Drawing(elements: elements))
        var o = ExportOptions()
        o.dark = dark
        o.transparentBackground = true
        o.scale = 2
        o.padding = 8
        if let img = ExportService.renderImage(elements, clip: nil, scene: scene, assets: assets, options: o), let png = ExportService.pngData(img) {
            pb.setData(png, forType: .png)
        }
    }

    static func read(_ pb: NSPasteboard = .general) -> Content {
        if let data = pb.data(forType: .scrawlElements), let (els, assets) = decode(data) {
            return .elements(els, assets)
        }
        // Image files copied in Finder.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images: [(data: Data, ext: String?)] = urls.compactMap { url in
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                      let d = try? Data(contentsOf: url) else { return nil }
                return (d, url.pathExtension)
            }
            if !images.isEmpty { return .images(images) }
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.init(UTType.jpeg.identifier), "jpg"), (.init(UTType.heic.identifier), "heic"), (.tiff, "tiff")] {
            if let d = pb.data(forType: type) {
                // Normalize TIFF (the common screenshot/clipboard format) to PNG for compact storage.
                if ext == "tiff", let rep = NSBitmapImageRep(data: d), let png = rep.representation(using: .png, properties: [:]) {
                    return .images([(png, "png")])
                }
                return .images([(d, ext)])
            }
        }
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(s)
        }
        return .none
    }
}
