import AppKit

/// Contextual cursors. System cursors are used wherever macOS provides one.
enum Cursors {
    static func resize(_ handle: Handle, rotation: CGFloat) -> NSCursor {
        // Map the handle direction (adjusted for element rotation) to the nearest system resize cursor.
        let base: CGFloat
        switch handle {
        case .right: base = 0
        case .bottomRight: base = .pi / 4
        case .bottom: base = .pi / 2
        case .bottomLeft: base = 3 * .pi / 4
        case .left: base = .pi
        case .topLeft: base = -3 * .pi / 4
        case .top: base = -.pi / 2
        case .topRight: base = -.pi / 4
        default: return .arrow
        }
        let a = Geometry.normalizeAngle(base + rotation)
        let octant = Int(((a + .pi) / (.pi / 4)).rounded()) % 8
        // octant 0 = left, 2 = top, 4 = right, 6 = bottom
        let positions: [NSCursor.FrameResizePosition] = [.left, .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft]
        return NSCursor.frameResize(position: positions[octant], directions: .all)
    }

    static let rotate: NSCursor = symbolCursor("arrow.trianglehead.clockwise.rotate.90", fallback: .crosshair)
    static let eraser: NSCursor = circleCursor(diameter: 14)

    private static func symbolCursor(_ name: String, fallback: NSCursor) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return fallback }
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size, flipped: false) { rect in
            // White halo for contrast on any background.
            let tinted = { (color: NSColor) -> NSImage in
                let t = sym.copy() as! NSImage
                t.lockFocus()
                color.set()
                NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop)
                t.unlockFocus()
                return t
            }
            let s = sym.size
            let origin = NSPoint(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2)
            let halo = tinted(.white)
            for dx in [-1.0, 1.0] { for dy in [-1.0, 1.0] { halo.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .sourceOver, fraction: 1) } }
            tinted(.black).draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 11, y: 11))
    }

    private static func circleCursor(diameter d: CGFloat) -> NSCursor {
        let size = NSSize(width: d + 4, height: d + 4)
        let img = NSImage(size: size, flipped: false) { _ in
            let r = NSRect(x: 2, y: 2, width: d, height: d)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.black.withAlphaComponent(0.8).setStroke()
            let p = NSBezierPath(ovalIn: r)
            p.lineWidth = 1.5
            p.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }
}
