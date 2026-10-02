import AppKit

/// Converts Excalidraw JSON into editable Scrawl elements (not a screenshot).
enum ExcalidrawImporter {
    struct Result {
        var drawing: Drawing
        var assets: AssetStore
        var warnings: [String]
    }

    static func importDrawing(_ data: Data) throws -> Result {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["elements"] as? [[String: Any]] else {
            throw DocumentError.corrupt("not an Excalidraw file")
        }
        let assets = AssetStore()
        var fileAssets: [String: String] = [:]
        if let files = root["files"] as? [String: [String: Any]] {
            for (fileID, f) in files {
                guard let url = f["dataURL"] as? String, let comma = url.firstIndex(of: ","),
                      let bytes = Data(base64Encoded: String(url[url.index(after: comma)...])) else { continue }
                let mime = f["mimeType"] as? String ?? ""
                let ext = mime.contains("jpeg") ? "jpg" : mime.contains("svg") ? "svg" : mime.contains("gif") ? "gif" : mime.contains("webp") ? "webp" : "png"
                if let id = assets.add(data: bytes, fileExtension: ext) { fileAssets[fileID] = id }
            }
        }

        var idMap: [String: UUID] = [:]
        func uuid(_ s: String) -> UUID {
            if let u = idMap[s] { return u }
            let u = UUID(uuidString: s) ?? UUID()
            idMap[s] = u
            return u
        }

        var elements: [Element] = []
        var skipped: [String: Int] = [:]
        var pendingBindings: [(index: Int, start: String?, end: String?)] = []

        for item in raw {
            if item["isDeleted"] as? Bool == true { continue }
            guard let type = item["type"] as? String, let sid = item["id"] as? String else { continue }
            let x = num(item["x"]), y = num(item["y"])
            let w = max(0, num(item["width"])), h = max(0, num(item["height"]))
            var style = ElementStyle()
            style.strokeColor = color(item["strokeColor"] as? String, ink: true)
            style.fillColor = color(item["backgroundColor"] as? String, ink: false)
            switch item["fillStyle"] as? String {
            case "solid": style.fillStyle = .solid
            case "cross-hatch": style.fillStyle = .crossHatch
            default: style.fillStyle = .hachure
            }
            style.strokeWidth = max(0.5, num(item["strokeWidth"], default: 2))
            style.strokeStyle = StrokeStyle(rawValue: item["strokeStyle"] as? String ?? "") ?? .solid
            style.renderStyle = num(item["roughness"], default: 1) == 0 ? .precision : .ink
            style.opacity = max(0, min(1, num(item["opacity"], default: 100) / 100))
            if item["roundness"] is [String: Any] { style.cornerRadius = min(32, min(w, h) * 0.25) }

            let kind: ElementKind
            var frame = CGRect(x: x, y: y, width: w, height: h)
            switch type {
            case "rectangle": kind = .rectangle
            case "ellipse": kind = .ellipse
            case "diamond": kind = .diamond
            case "line", "arrow":
                let pts = points(item["points"])
                let world = (pts.count >= 2 ? pts : [.zero, CGPoint(x: w, y: h)]).map { $0 + CGPoint(x: x, y: y) }
                style.startArrowhead = arrowhead(item["startArrowhead"])
                style.endArrowhead = arrowhead(item["endArrowhead"])
                if item["elbowed"] as? Bool == true { style.routing = .elbow }
                else if item["roundness"] is [String: Any] && pts.count > 2 { style.routing = .curved }
                style.cornerRadius = 0
                let d = LinearData(points: [], startBinding: nil, endBinding: nil)
                var e = Element(id: uuid(sid), kind: type == "arrow" ? .arrow(d) : .line(d), frame: frame, style: style)
                e.setLinearWorldPoints(world)
                finish(&e, item, uuid: uuid)
                elements.append(e)
                pendingBindings.append((elements.count - 1, (item["startBinding"] as? [String: Any])?["elementId"] as? String,
                                        (item["endBinding"] as? [String: Any])?["elementId"] as? String))
                continue
            case "freedraw":
                let pts = points(item["points"])
                guard !pts.isEmpty else { skipped[type, default: 0] += 1; continue }
                let world = pts.map { $0 + CGPoint(x: x, y: y) }
                let box = CGRect.bounding(world) ?? frame
                frame = box
                var pressures = (item["pressures"] as? [Any])?.map { num($0) } ?? []
                if pressures.count != pts.count || item["simulatePressure"] as? Bool == true { pressures = [] }
                kind = .freehand(FreehandData(points: world.map { $0 - box.origin }, pressures: pressures))
            case "text":
                let size = num(item["fontSize"], default: 20)
                style.fontSize = size
                switch Int(num(item["fontFamily"], default: 1)) {
                case 2, 6, 7: style.fontFamily = .sans
                case 3, 8: style.fontFamily = .mono
                default: style.fontFamily = .hand
                }
                style.textAlign = TextAlign(rawValue: item["textAlign"] as? String ?? "") ?? .left
                let text = item["originalText"] as? String ?? item["text"] as? String ?? ""
                kind = .text(TextData(text: text, autoWidth: (item["autoResize"] as? Bool) ?? true))
            case "image":
                guard let fid = item["fileId"] as? String, let asset = fileAssets[fid] else { skipped[type, default: 0] += 1; continue }
                var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                if let c = item["crop"] as? [String: Any], let nw = c["naturalWidth"], let nh = c["naturalHeight"] {
                    let NW = max(1, num(nw)), NH = max(1, num(nh))
                    crop = CGRect(x: num(c["x"]) / NW, y: num(c["y"]) / NH, width: num(c["width"], default: NW) / NW, height: num(c["height"], default: NH) / NH)
                }
                style.strokeWidth = 0
                kind = .image(ImageData(assetID: asset, crop: crop))
            case "frame", "magicframe":
                kind = .frame(FrameData(name: item["name"] as? String ?? "Frame"))
                style.fillColor = .clear
            default:
                skipped[type, default: 0] += 1
                continue
            }
            var e = Element(id: uuid(sid), kind: kind, frame: frame, rotation: num(item["angle"]), style: style)
            if e.isText { TextLayout.fit(&e); e.frame.origin = CGPoint(x: x, y: y) }
            finish(&e, item, uuid: uuid)
            elements.append(e)
        }

        // Resolve bindings now that every target exists.
        let byID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
        for pb in pendingBindings {
            var e = elements[pb.index]
            guard var d = e.linear else { continue }
            let pts = e.worldPoints
            func binding(_ sid: String?, at p: CGPoint?) -> ConnectorBinding? {
                guard let sid, let target = idMap[sid].flatMap({ byID[$0] }), target.isBindable, let p else { return nil }
                var u = target.frame.unitPoint(of: target.toLocal(p))
                u.x = max(0, min(1, u.x)); u.y = max(0, min(1, u.y))
                return ConnectorBinding(elementID: target.id, anchor: u)
            }
            d.startBinding = binding(pb.start, at: pts.first)
            d.endBinding = binding(pb.end, at: pts.last)
            e.linear = d
            elements[pb.index] = e
        }

        // Frames go to the back.
        elements = elements.filter(\.isFrame) + elements.filter { !$0.isFrame }

        var settings = Preferences.shared.defaultSettings
        if let app = root["appState"] as? [String: Any] {
            if let bg = app["viewBackgroundColor"] as? String, let c = DrawingColor.parse(bg), bg.lowercased() != "#ffffff" { settings.background = c }
            if let g = app["gridSize"] as? Double, g >= 4 { settings.gridSpacing = g }
        }
        var warnings: [String] = []
        for (t, n) in skipped.sorted(by: { $0.key < $1.key }) { warnings.append("\(n) unsupported “\(t)” element\(n == 1 ? " was" : "s were") skipped.") }
        return Result(drawing: Drawing(elements: elements, settings: settings), assets: assets, warnings: warnings)
    }

    private static func finish(_ e: inout Element, _ item: [String: Any], uuid: (String) -> UUID) {
        e.isLocked = item["locked"] as? Bool ?? false
        e.groupIDs = (item["groupIds"] as? [String] ?? []).map(uuid)
        e.frameID = (item["frameId"] as? String).map(uuid)
        if let seed = item["seed"] as? Int { e.seed = UInt32(truncatingIfNeeded: seed) }
    }

    private static func num(_ v: Any?, default d: Double = 0) -> Double {
        if let n = v as? Double, n.isFinite { return n }
        if let n = v as? Int { return Double(n) }
        if let n = v as? NSNumber { return n.doubleValue }
        return d
    }

    private static func points(_ v: Any?) -> [CGPoint] {
        guard let arr = v as? [[Any]] else { return [] }
        return arr.compactMap { p in p.count >= 2 ? CGPoint(x: num(p[0]), y: num(p[1])) : nil }
    }

    private static func color(_ s: String?, ink: Bool) -> DrawingColor {
        guard let s else { return ink ? .ink : .clear }
        let l = s.lowercased()
        if ink && (l == "#1e1e1e" || l == "#000000" || l == "#000" || l == "black") { return .ink }
        return DrawingColor.parse(s) ?? (ink ? .ink : .clear)
    }

    private static func arrowhead(_ v: Any?) -> Arrowhead {
        switch v as? String {
        case "arrow": return .arrow
        case "triangle", "triangle_outline": return .triangle
        case "dot", "circle", "circle_outline": return .dot
        case "bar": return .bar
        default: return .none
        }
    }
}
