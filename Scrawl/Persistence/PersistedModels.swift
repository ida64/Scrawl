import CoreGraphics
import Foundation

// Explicit, versioned on-disk representation. Runtime types are never serialized directly, so
// the model can evolve while the file format stays stable and migratable.

struct PersistedDocument: Codable {
    var format: String = "scrawl"
    var version: Int
    var generator: String?
    var settings: PersistedSettings?
    var elements: [Lenient<PersistedElement>]
    var assets: [PersistedAssetRef]?
}

struct PersistedSettings: Codable, Equatable {
    var background: String?
    var grid: String?
    var gridSpacing: Double?
}

struct PersistedAssetRef: Codable, Equatable {
    var id: String
    var file: String
}

struct PersistedBinding: Codable, Equatable {
    var elementId: String
    var anchor: [Double]
}

struct PersistedStyle: Codable, Equatable {
    var stroke: String?
    var fill: String?
    var fillStyle: String?
    var strokeWidth: Double?
    var strokeStyle: String?
    var opacity: Double?
    var render: String?
    var cornerRadius: Double?
    var fontFamily: String?
    var fontSize: Double?
    var fontWeight: String?
    var textAlign: String?
    var startArrowhead: String?
    var endArrowhead: String?
    var routing: String?
    var fontName: String?
    var lineHeight: Double?
}

struct PersistedElement: Codable, Equatable {
    var id: String
    var type: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotation: Double?
    var seed: UInt32?
    var locked: Bool?
    var groupIds: [String]?
    var frameId: String?
    var style: PersistedStyle?
    // Type-specific payloads
    var points: [[Double]]?
    var pressures: [Double]?
    var startBinding: PersistedBinding?
    var endBinding: PersistedBinding?
    var text: String?
    var autoWidth: Bool?
    var assetId: String?
    var crop: [Double]?
    var name: String?
    var title: String?
    var hidden: Bool?
}

/// Decodes a value, capturing failures instead of throwing, so one malformed element doesn't
/// make the whole document unreadable.
struct Lenient<T: Codable>: Codable {
    var value: T?
    var error: String?

    init(_ value: T) { self.value = value }

    init(from decoder: Decoder) throws {
        do {
            value = try T(from: decoder)
        } catch {
            value = nil
            self.error = String(describing: error)
        }
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

// MARK: - Mapping: runtime → persisted

enum PersistenceMapping {
    static func round(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }

    static func persist(_ s: ElementStyle) -> PersistedStyle {
        PersistedStyle(
            stroke: s.strokeColor.serialized, fill: s.fillColor.serialized, fillStyle: s.fillStyle.rawValue,
            strokeWidth: s.strokeWidth, strokeStyle: s.strokeStyle.rawValue, opacity: s.opacity,
            render: s.renderStyle.rawValue, cornerRadius: s.cornerRadius, fontFamily: s.fontFamily.rawValue,
            fontSize: s.fontSize, fontWeight: s.fontWeight.rawValue, textAlign: s.textAlign.rawValue,
            startArrowhead: s.startArrowhead.rawValue, endArrowhead: s.endArrowhead.rawValue, routing: s.routing.rawValue,
            fontName: s.fontName, lineHeight: s.lineHeight)
    }

    static func persist(_ e: Element) -> PersistedElement {
        var p = PersistedElement(
            id: e.id.uuidString, type: e.type.rawValue,
            x: round(e.frame.minX), y: round(e.frame.minY), width: round(e.frame.width), height: round(e.frame.height),
            rotation: e.rotation == 0 ? nil : Double(e.rotation), seed: e.seed, locked: e.isLocked ? true : nil,
            groupIds: e.groupIDs.isEmpty ? nil : e.groupIDs.map(\.uuidString), frameId: e.frameID?.uuidString,
            style: persist(e.style))
        p.title = e.name
        p.hidden = e.isHidden ? true : nil
        func binding(_ b: ConnectorBinding?) -> PersistedBinding? {
            b.map { PersistedBinding(elementId: $0.elementID.uuidString, anchor: [(Double($0.anchor.x) * 10000).rounded() / 10000, (Double($0.anchor.y) * 10000).rounded() / 10000]) }
        }
        switch e.kind {
        case .rectangle, .ellipse, .diamond:
            break
        case let .line(d), let .arrow(d):
            p.points = d.points.map { [round($0.x), round($0.y)] }
            p.startBinding = binding(d.startBinding)
            p.endBinding = binding(d.endBinding)
        case let .freehand(d):
            p.points = d.points.map { [round($0.x), round($0.y)] }
            p.pressures = d.pressures.isEmpty ? nil : d.pressures.map { ($0 * 1000).rounded() / 1000 }
        case let .text(t):
            p.text = t.text
            p.autoWidth = t.autoWidth
        case let .image(i):
            p.assetId = i.assetID
            let c = i.crop
            if c != CGRect(x: 0, y: 0, width: 1, height: 1) { p.crop = [Double(c.minX), Double(c.minY), Double(c.width), Double(c.height)] }
        case let .frame(f):
            p.name = f.name
        }
        return p
    }

    static func persist(_ s: DrawingSettings) -> PersistedSettings {
        PersistedSettings(background: s.background?.serialized, grid: s.grid.rawValue, gridSpacing: s.gridSpacing)
    }

    // MARK: Mapping: persisted → runtime

    enum MappingError: Error, CustomStringConvertible {
        case unknownType(String)
        case invalidGeometry(String)

        var description: String {
            switch self {
            case let .unknownType(t): return "Unsupported element type “\(t)”"
            case let .invalidGeometry(id): return "Element \(id) has invalid geometry"
            }
        }
    }

    static func style(_ p: PersistedStyle?) -> ElementStyle {
        var s = ElementStyle()
        guard let p else { return s }
        if let v = p.stroke.flatMap({ DrawingColor.parse($0) }) { s.strokeColor = v }
        if let v = p.fill.flatMap({ DrawingColor.parse($0) }) { s.fillColor = v }
        if let v = p.fillStyle.flatMap({ FillStyle(rawValue: $0) }) { s.fillStyle = v }
        if let v = p.strokeWidth, v.isFinite { s.strokeWidth = max(0, min(v, 200)) }
        if let v = p.strokeStyle.flatMap({ StrokeStyle(rawValue: $0) }) { s.strokeStyle = v }
        if let v = p.opacity, v.isFinite { s.opacity = max(0, min(1, v)) }
        if let v = p.render.flatMap({ RenderStyle(persisted: $0) }) { s.renderStyle = v }
        if let v = p.cornerRadius, v.isFinite { s.cornerRadius = max(0, v) }
        if let v = p.fontFamily.flatMap({ FontFamily(rawValue: $0) }) { s.fontFamily = v }
        if let v = p.fontSize, v.isFinite { s.fontSize = max(1, min(v, 2000)) }
        if let v = p.fontWeight.flatMap({ FontWeightOption(rawValue: $0) }) { s.fontWeight = v }
        if let v = p.textAlign.flatMap({ TextAlign(rawValue: $0) }) { s.textAlign = v }
        if let v = p.startArrowhead.flatMap({ Arrowhead(rawValue: $0) }) { s.startArrowhead = v }
        if let v = p.endArrowhead.flatMap({ Arrowhead(rawValue: $0) }) { s.endArrowhead = v }
        if let v = p.routing.flatMap({ LineRouting(rawValue: $0) }) { s.routing = v }
        if let v = p.fontName, !v.isEmpty { s.fontName = v }
        if let v = p.lineHeight, v.isFinite { s.lineHeight = max(0.6, min(3, v)) }
        return s
    }

    static func point(_ a: [Double]) -> CGPoint? {
        guard a.count >= 2, a[0].isFinite, a[1].isFinite else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }

    static func binding(_ p: PersistedBinding?) -> ConnectorBinding? {
        guard let p, let id = UUID(uuidString: p.elementId) else { return nil }
        let a = point(p.anchor) ?? CGPoint(x: 0.5, y: 0.5)
        return ConnectorBinding(elementID: id, anchor: CGPoint(x: max(0, min(1, a.x)), y: max(0, min(1, a.y))))
    }

    static func element(_ p: PersistedElement) throws -> Element {
        let frame = CGRect(x: p.x, y: p.y, width: p.width, height: p.height)
        guard frame.isFiniteRect, p.width >= 0, p.height >= 0, abs(p.x) < 1e12, abs(p.y) < 1e12 else {
            throw MappingError.invalidGeometry(p.id)
        }
        let id = UUID(uuidString: p.id) ?? UUID()
        let pts = (p.points ?? []).compactMap { point($0) }
        let kind: ElementKind
        switch p.type {
        case "rectangle": kind = .rectangle
        case "ellipse": kind = .ellipse
        case "diamond": kind = .diamond
        case "line", "arrow":
            let d = LinearData(points: pts.count >= 2 ? pts : [.zero, CGPoint(x: frame.width, y: frame.height)],
                               startBinding: binding(p.startBinding), endBinding: binding(p.endBinding))
            kind = p.type == "line" ? .line(d) : .arrow(d)
        case "freehand":
            guard !pts.isEmpty else { throw MappingError.invalidGeometry(p.id) }
            kind = .freehand(FreehandData(points: pts, pressures: p.pressures?.count == pts.count ? p.pressures ?? [] : []))
        case "text":
            kind = .text(TextData(text: p.text ?? "", autoWidth: p.autoWidth ?? true))
        case "image":
            var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
            if let c = p.crop, c.count == 4, c.allSatisfy(\.isFinite), c[2] > 0, c[3] > 0 { crop = CGRect(x: c[0], y: c[1], width: c[2], height: c[3]) }
            kind = .image(ImageData(assetID: p.assetId ?? "", crop: crop))
        case "frame":
            kind = .frame(FrameData(name: p.name ?? "Frame"))
        default:
            throw MappingError.unknownType(p.type)
        }
        let rotation = p.rotation.flatMap { $0.isFinite ? CGFloat($0) : nil } ?? 0
        return Element(id: id, kind: kind, frame: frame, rotation: rotation, style: style(p.style), isLocked: p.locked ?? false,
                       groupIDs: (p.groupIds ?? []).compactMap { UUID(uuidString: $0) }, frameID: p.frameId.flatMap { UUID(uuidString: $0) },
                       seed: p.seed ?? stableSeed(id), name: p.title, isHidden: p.hidden ?? false)
    }

    /// Deterministic seed derived from an element ID (for files without stored seeds).
    static func stableSeed(_ id: UUID) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        withUnsafeBytes(of: id.uuid) { for b in $0 { h = (h ^ UInt32(b)) &* 16_777_619 } }
        return h == 0 ? 1 : h
    }

    static func settings(_ p: PersistedSettings?) -> DrawingSettings {
        var s = DrawingSettings()
        guard let p else { return s }
        s.background = p.background.flatMap { DrawingColor.parse($0) }
        if let g = p.grid.flatMap({ GridStyle(rawValue: $0) }) { s.grid = g }
        if let v = p.gridSpacing, v.isFinite, v >= 4, v <= 400 { s.gridSpacing = v }
        return s
    }
}
