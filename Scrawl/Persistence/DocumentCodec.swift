import AppKit

enum DocumentError: LocalizedError {
    case notAScrawlDocument
    case missingContent
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .notAScrawlDocument: return "This file isn’t a Scrawl drawing."
        case .missingContent: return "The drawing is missing its content file (document.json)."
        case let .corrupt(detail): return "The drawing couldn’t be read because its content is damaged. (\(detail))"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingContent, .corrupt: return "If you have a Time Machine backup or an earlier version, try restoring it with File ▸ Revert To."
        case .notAScrawlDocument: return nil
        }
    }
}

/// Upgrades raw document JSON from older format versions, one step at a time. Migrations run
/// on untyped JSON before decoding so old layouts never need to be representable in Swift types.
struct DocumentMigrator {
    typealias Step = (inout [String: Any]) throws -> Void

    static let currentVersion = 2

    /// `steps[n]` upgrades a document from version n to n + 1.
    var steps: [Int: Step]
    var targetVersion: Int

    static let standard = DocumentMigrator(steps: [1: migrateV1RenderStyles], targetVersion: currentVersion)

    /// v1 → v2: render styles were renamed (clean/technical → precision, sketch → ink).
    nonisolated static func migrateV1RenderStyles(_ json: inout [String: Any]) throws {
        guard var elements = json["elements"] as? [[String: Any]] else { return }
        let map = ["clean": "precision", "technical": "precision", "sketch": "ink"]
        for i in elements.indices {
            guard var style = elements[i]["style"] as? [String: Any], let r = style["render"] as? String, let new = map[r] else { continue }
            style["render"] = new
            elements[i]["style"] = style
        }
        json["elements"] = elements
    }

    struct Outcome {
        var originalVersion: Int
        var warnings: [String] = []
    }

    func migrate(_ json: inout [String: Any]) throws -> Outcome {
        let original = (json["version"] as? Int) ?? 0
        var outcome = Outcome(originalVersion: original)
        if original > targetVersion {
            outcome.warnings.append("This drawing was created by a newer version of Scrawl. Some content may not appear.")
            return outcome
        }
        var v = original
        while v < targetVersion {
            if let step = steps[v] { try step(&json) }
            v += 1
            json["version"] = v
        }
        return outcome
    }
}

/// Reads and writes the `.scrawl` package:
///
///     Drawing.scrawl/
///       document.json   versioned, deterministic (sorted keys)
///       assets/         embedded images, content-addressed by hash
///       preview.png     thumbnail
enum DocumentCodec {
    static let contentFile = "document.json"
    static let assetsDirectory = "assets"
    static let previewFile = "preview.png"

    struct Decoded {
        var drawing: Drawing
        var assets: AssetStore
        var warnings: [String]
    }

    // MARK: JSON

    static func encodeJSON(_ drawing: Drawing, assets: AssetStore? = nil) throws -> Data {
        let usedAssets = Set(drawing.elements.compactMap { e -> String? in
            if case let .image(i) = e.kind { return i.assetID }
            return nil
        })
        let refs = (assets?.ids ?? []).filter(usedAssets.contains).compactMap { id -> PersistedAssetRef? in
            guard let a = assets?.asset(id) else { return nil }
            return PersistedAssetRef(id: id, file: "\(assetsDirectory)/\(id).\(a.fileExtension)")
        }
        let doc = PersistedDocument(
            version: DocumentMigrator.currentVersion,
            generator: "Scrawl \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")",
            settings: PersistenceMapping.persist(drawing.settings),
            elements: drawing.elements.map { Lenient(PersistenceMapping.persist($0)) },
            assets: refs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }

    static func decodeJSON(_ data: Data, migrator: DocumentMigrator = .standard) throws -> (Drawing, [PersistedAssetRef], [String]) {
        guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DocumentError.corrupt("invalid JSON")
        }
        if let format = json["format"] as? String, format != "scrawl" { throw DocumentError.notAScrawlDocument }
        let outcome: DocumentMigrator.Outcome
        do { outcome = try migrator.migrate(&json) } catch { throw DocumentError.corrupt("migration failed: \(error.localizedDescription)") }
        var warnings = outcome.warnings
        let migrated = try JSONSerialization.data(withJSONObject: json)
        let doc: PersistedDocument
        do {
            doc = try JSONDecoder().decode(PersistedDocument.self, from: migrated)
        } catch {
            throw DocumentError.corrupt("unexpected structure")
        }
        var elements: [Element] = []
        var seen = Set<ElementID>()
        var skipped = 0
        for item in doc.elements {
            guard let p = item.value, var e = try? PersistenceMapping.element(p) else { skipped += 1; continue }
            if !seen.insert(e.id).inserted { e.id = UUID() }
            elements.append(e)
        }
        // Drop dangling references rather than failing.
        let ids = Set(elements.map(\.id))
        for i in elements.indices {
            if let f = elements[i].frameID, !ids.contains(f) { elements[i].frameID = nil }
            if var d = elements[i].linear {
                if let b = d.startBinding, !ids.contains(b.elementID) { d.startBinding = nil }
                if let b = d.endBinding, !ids.contains(b.elementID) { d.endBinding = nil }
                elements[i].linear = d
            }
        }
        if skipped > 0 {
            warnings.append("\(skipped) item\(skipped == 1 ? "" : "s") couldn’t be read and \(skipped == 1 ? "was" : "were") skipped.")
        }
        let drawing = Drawing(elements: elements, settings: PersistenceMapping.settings(doc.settings))
        return (drawing, doc.assets ?? [], warnings)
    }

    // MARK: Package

    static func fileWrapper(for drawing: Drawing, assets: AssetStore, preview: Data?, reusing previous: FileWrapper?) throws -> FileWrapper {
        let json = try encodeJSON(drawing, assets: assets)
        var children: [String: FileWrapper] = [contentFile: FileWrapper(regularFileWithContents: json)]

        let used = Set(drawing.elements.compactMap { e -> String? in
            if case let .image(i) = e.kind { return i.assetID }
            return nil
        })
        if !used.isEmpty {
            let previousAssets = previous?.fileWrappers?[assetsDirectory]?.fileWrappers ?? [:]
            var assetChildren: [String: FileWrapper] = [:]
            for id in used.sorted() {
                guard let a = assets.asset(id) else { continue }
                let name = "\(id).\(a.fileExtension)"
                // Reuse unchanged asset wrappers so saves don't rewrite large images.
                if let old = previousAssets[name], old.isRegularFile {
                    let w = FileWrapper(regularFileWithContents: old.regularFileContents ?? a.data)
                    w.preferredFilename = name
                    assetChildren[name] = w
                } else {
                    let w = FileWrapper(regularFileWithContents: a.data)
                    w.preferredFilename = name
                    assetChildren[name] = w
                }
            }
            let dir = FileWrapper(directoryWithFileWrappers: assetChildren)
            dir.preferredFilename = assetsDirectory
            children[assetsDirectory] = dir
        }
        if let preview { children[previewFile] = FileWrapper(regularFileWithContents: preview) }
        for (name, w) in children { w.preferredFilename = name }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    static func decode(_ wrapper: FileWrapper) throws -> Decoded {
        if wrapper.isRegularFile, let data = wrapper.regularFileContents {
            // A bare JSON file (e.g. renamed document.json) — be forgiving.
            let (drawing, _, warnings) = try decodeJSON(data)
            return Decoded(drawing: drawing, assets: AssetStore(), warnings: warnings)
        }
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else { throw DocumentError.notAScrawlDocument }
        guard let data = children[contentFile]?.regularFileContents else { throw DocumentError.missingContent }
        var (drawing, refs, warnings) = try decodeJSON(data)
        let store = AssetStore()
        let assetFiles = children[assetsDirectory]?.fileWrappers ?? [:]
        var missing = 0
        let refByID = Dictionary(refs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let neededIDs = Set(drawing.elements.compactMap { e -> String? in
            if case let .image(i) = e.kind { return i.assetID }
            return nil
        })
        for id in neededIDs {
            let fileName = refByID[id].map { ($0.file as NSString).lastPathComponent }
                ?? assetFiles.keys.first { ($0 as NSString).deletingPathExtension == id }
            guard let name = fileName, let data = assetFiles[name]?.regularFileContents else { missing += 1; continue }
            store.insert(.init(id: id, data: data, fileExtension: (name as NSString).pathExtension))
        }
        if missing > 0 { warnings.append("\(missing) image\(missing == 1 ? " is" : "s are") missing from the file and will show as placeholders.") }
        drawing.settings.gridSpacing = max(4, drawing.settings.gridSpacing)
        return Decoded(drawing: drawing, assets: store, warnings: warnings)
    }
}
