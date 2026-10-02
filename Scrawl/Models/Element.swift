import CoreGraphics
import Foundation

typealias ElementID = UUID

/// A structural attachment from a connector endpoint to another element. The endpoint position
/// is derived from the target's geometry at render/update time, never baked in permanently.
struct ConnectorBinding: Equatable, Sendable {
    var elementID: ElementID
    /// Normalized focus point inside the target's unrotated bounds (0...1 on each axis).
    var anchor: CGPoint
}

struct LinearData: Equatable, Sendable {
    /// Points relative to the element frame origin. Linear elements keep `rotation == 0` and
    /// bake rotation into their points, which keeps binding math simple.
    var points: [CGPoint]
    var startBinding: ConnectorBinding?
    var endBinding: ConnectorBinding?
}

struct FreehandData: Equatable, Sendable {
    /// Points relative to the element frame origin.
    var points: [CGPoint]
    /// Per-point pressure in 0...1 (real tablet pressure or simulated from velocity). May be empty.
    var pressures: [Double]
}

struct TextData: Equatable, Sendable {
    var text: String
    /// When true the box grows to fit its longest line; otherwise text wraps at the frame width.
    var autoWidth: Bool
}

struct ImageData: Equatable, Sendable {
    var assetID: String
    /// Visible region of the source image, normalized (0...1).
    var crop: CGRect
}

struct FrameData: Equatable, Sendable {
    var name: String
}

enum ElementType: String, CaseIterable, Sendable {
    case rectangle, ellipse, diamond, line, arrow, freehand, text, image, frame

    var displayName: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .diamond: return "Diamond"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .freehand: return "Drawing"
        case .text: return "Text"
        case .image: return "Image"
        case .frame: return "Frame"
        }
    }
}

enum ElementKind: Equatable, Sendable {
    case rectangle
    case ellipse
    case diamond
    case line(LinearData)
    case arrow(LinearData)
    case freehand(FreehandData)
    case text(TextData)
    case image(ImageData)
    case frame(FrameData)

    var type: ElementType {
        switch self {
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .diamond: return .diamond
        case .line: return .line
        case .arrow: return .arrow
        case .freehand: return .freehand
        case .text: return .text
        case .image: return .image
        case .frame: return .frame
        }
    }
}

/// One object on the canvas: a shared core (identity, geometry, style, structure) plus a typed payload.
struct Element: Identifiable, Equatable, Sendable {
    var id: ElementID
    var kind: ElementKind
    /// Unrotated bounds in world coordinates. Rotation is applied around `frame.center`.
    var frame: CGRect
    var rotation: CGFloat = 0
    var style: ElementStyle
    var isLocked: Bool = false
    /// Group membership, innermost group first.
    var groupIDs: [UUID] = []
    /// The frame (artboard) that contains this element, if any.
    var frameID: ElementID?
    /// Stable seed for deterministic sketch rendering.
    var seed: UInt32
    /// Optional user-facing name shown in the layers sidebar.
    var name: String?
    /// Hidden elements stay in the document but are not drawn, exported or hit-tested.
    var isHidden: Bool = false

    init(id: ElementID = UUID(), kind: ElementKind, frame: CGRect, rotation: CGFloat = 0,
         style: ElementStyle, isLocked: Bool = false, groupIDs: [UUID] = [], frameID: ElementID? = nil,
         seed: UInt32 = SeededRandom.randomSeed(), name: String? = nil, isHidden: Bool = false) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.rotation = rotation
        self.style = style
        self.isLocked = isLocked
        self.groupIDs = groupIDs
        self.frameID = frameID
        self.seed = seed
        self.name = name
        self.isHidden = isHidden
    }

    /// Name for lists: the user's name, the frame name, a text excerpt, or the type.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        switch kind {
        case let .frame(f): return f.name.isEmpty ? "Frame" : f.name
        case let .text(t):
            let line = t.text.split(separator: "\n").first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Text" : String(trimmed.prefix(40))
        default: return type.displayName
        }
    }

    var type: ElementType { kind.type }
    var center: CGPoint { frame.center }

    /// Axis-aligned world bounds including rotation (not including stroke width).
    var bounds: CGRect { frame.rotatedBounds(rotation) }

    /// Bounds padded for stroke width, arrowheads and sketch jitter; used for culling and indexing.
    var renderBounds: CGRect {
        var pad = CGFloat(style.strokeWidth) * 2 + 4
        if style.renderStyle == .ink { pad += 6 }
        if case .arrow = kind { pad += CGFloat(style.strokeWidth) * 4 + 12 }
        if case .frame = kind { pad += 24 }
        return bounds.expanded(by: pad)
    }

    var isLinear: Bool {
        switch kind {
        case .line, .arrow: return true
        default: return false
        }
    }

    var isFrame: Bool { if case .frame = kind { return true }; return false }
    var isText: Bool { if case .text = kind { return true }; return false }

    /// Shapes that connectors can attach to.
    var isBindable: Bool {
        switch kind {
        case .rectangle, .ellipse, .diamond, .text, .image: return true
        default: return false
        }
    }

    var supportsFill: Bool {
        switch kind {
        case .rectangle, .ellipse, .diamond: return true
        default: return false
        }
    }

    var linear: LinearData? {
        get {
            switch kind {
            case let .line(d), let .arrow(d): return d
            default: return nil
            }
        }
        set {
            guard let newValue else { return }
            switch kind {
            case .line: kind = .line(newValue)
            case .arrow: kind = .arrow(newValue)
            default: break
            }
        }
    }

    var textData: TextData? {
        if case let .text(t) = kind { return t }
        return nil
    }

    var frameData: FrameData? {
        if case let .frame(f) = kind { return f }
        return nil
    }

    /// Outermost group, which defines what a click selects.
    var outermostGroupID: UUID? { groupIDs.last }

    // MARK: Coordinate conversion

    /// Converts a world point into this element's local, unrotated frame space.
    func toLocal(_ world: CGPoint) -> CGPoint {
        world.rotated(around: center, by: -rotation)
    }

    func toWorld(_ local: CGPoint) -> CGPoint {
        local.rotated(around: center, by: rotation)
    }

    /// World-space points of a linear or freehand element.
    var worldPoints: [CGPoint] {
        let o = frame.origin
        switch kind {
        case let .line(d), let .arrow(d):
            return d.points.map { $0 + o }
        case let .freehand(d):
            return d.points.map { toWorld($0 + o) }
        default:
            return []
        }
    }

    /// Replaces the points of a linear element (given in world space) and re-normalizes its frame.
    mutating func setLinearWorldPoints(_ world: [CGPoint]) {
        guard var d = linear, let box = CGRect.bounding(world) else { return }
        d.points = world.map { $0 - box.origin }
        frame = box
        rotation = 0
        linear = d
    }

    // MARK: Geometric transforms

    mutating func translate(by delta: CGPoint) {
        frame.origin += delta
    }

    /// Resizes the element to a new unrotated frame, scaling inner geometry as needed.
    mutating func resize(to newFrame: CGRect) {
        let old = frame
        let sx = old.width > 0 ? newFrame.width / old.width : 1
        let sy = old.height > 0 ? newFrame.height / old.height : 1
        switch kind {
        case var .line(d):
            d.points = d.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            kind = .line(d)
        case var .arrow(d):
            d.points = d.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            kind = .arrow(d)
        case var .freehand(d):
            d.points = d.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            kind = .freehand(d)
        default:
            break
        }
        frame = newFrame
    }
}
