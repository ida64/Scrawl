import CoreGraphics
import Foundation

/// Maps between world coordinates (the drawing) and screen coordinates (view points, y-down).
///
///     screen = (world - origin) * zoom
///
/// `origin` is the world point at the view's top-left corner. Using Double-precision CGFloat
/// for both keeps precision well beyond any coordinate a person can reach by panning.
struct CanvasViewport: Equatable, Sendable {
    var origin: CGPoint = .zero
    var zoom: CGFloat = 1

    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 32

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - origin.x) * zoom, y: (p.y - origin.y) * zoom)
    }

    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / zoom + origin.x, y: p.y / zoom + origin.y)
    }

    func toScreen(_ r: CGRect) -> CGRect {
        CGRect(origin: toScreen(r.origin), size: CGSize(width: r.width * zoom, height: r.height * zoom))
    }

    func toWorld(_ r: CGRect) -> CGRect {
        CGRect(origin: toWorld(r.origin), size: CGSize(width: r.width / zoom, height: r.height / zoom))
    }

    /// Converts a screen-space distance (e.g. a hit tolerance) into world units.
    func worldLength(_ screen: CGFloat) -> CGFloat { screen / zoom }

    /// Visible world rect for a view of the given size.
    func visibleWorldRect(viewSize: CGSize) -> CGRect {
        toWorld(CGRect(origin: .zero, size: viewSize))
    }

    /// The affine transform from world to screen space.
    var transform: CGAffineTransform {
        CGAffineTransform(scaleX: zoom, y: zoom).translatedBy(x: -origin.x, y: -origin.y)
    }

    mutating func pan(byScreenDelta d: CGPoint) {
        origin.x -= d.x / zoom
        origin.y -= d.y / zoom
    }

    /// Zooms so that the world point under `screenPoint` stays fixed.
    mutating func zoom(to newZoom: CGFloat, anchor screenPoint: CGPoint) {
        let z = CanvasViewport.clampZoom(newZoom)
        let world = toWorld(screenPoint)
        zoom = z
        origin = CGPoint(x: world.x - screenPoint.x / z, y: world.y - screenPoint.y / z)
    }

    /// Centers the viewport on a world point.
    mutating func center(on world: CGPoint, viewSize: CGSize) {
        origin = CGPoint(x: world.x - viewSize.width / 2 / zoom, y: world.y - viewSize.height / 2 / zoom)
    }

    /// Returns a viewport that fits `rect` into the view with screen-space padding.
    static func fitting(_ rect: CGRect, viewSize: CGSize, padding: CGFloat = 64, maxZoom: CGFloat = 2) -> CanvasViewport {
        guard viewSize.width > 0, viewSize.height > 0 else { return CanvasViewport() }
        let r = rect.width < 1 && rect.height < 1 ? rect.expanded(by: 50) : rect
        let availW = max(1, viewSize.width - padding * 2)
        let availH = max(1, viewSize.height - padding * 2)
        let z = clampZoom(min(availW / max(r.width, 1), availH / max(r.height, 1), maxZoom))
        var v = CanvasViewport(origin: .zero, zoom: z)
        v.center(on: r.center, viewSize: viewSize)
        return v
    }

    static func clampZoom(_ z: CGFloat) -> CGFloat {
        guard z.isFinite else { return 1 }
        return min(maxZoom, max(minZoom, z))
    }

    /// Discrete zoom steps used by the zoom buttons and ⌘+ / ⌘−.
    static let steps: [CGFloat] = [0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32]

    static func nextStep(after z: CGFloat) -> CGFloat {
        steps.first { $0 > z * 1.001 } ?? maxZoom
    }

    static func previousStep(before z: CGFloat) -> CGFloat {
        steps.last { $0 < z * 0.999 } ?? minZoom
    }
}
