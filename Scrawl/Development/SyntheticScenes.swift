import CoreGraphics
import Foundation

/// Deterministic large scenes for performance measurement (Help ▸ Developer, and tests).
enum SyntheticScenes {
    static func make(count: Int, seed: UInt32 = 42) -> Drawing {
        var rng = SeededRandom(seed: seed)
        var elements: [Element] = []
        elements.reserveCapacity(count)
        let columns = max(1, Int(Double(count).squareRoot()))
        let colors = Palette.stroke
        for i in 0..<count {
            let col = i % columns, row = i / columns
            let origin = CGPoint(x: CGFloat(col) * 160 + CGFloat(rng.range(-20, 20)), y: CGFloat(row) * 130 + CGFloat(rng.range(-20, 20)))
            var style = ElementStyle()
            style.strokeColor = colors[Int(rng.next() * Double(colors.count)) % colors.count]
            style.renderStyle = rng.next() < 0.3 ? .ink : .precision
            if rng.next() < 0.4 { style.fillColor = Palette.fill[1 + Int(rng.next() * 8) % 8] }
            let size = CGSize(width: rng.range(40, 120), height: rng.range(30, 90))
            let frame = CGRect(origin: origin, size: size)
            let kind: ElementKind
            switch i % 7 {
            case 0: kind = .rectangle
            case 1: kind = .ellipse
            case 2: kind = .diamond
            case 3:
                kind = .arrow(LinearData(points: [.zero, CGPoint(x: size.width, y: size.height * 0.5)]))
            case 4:
                var pts: [CGPoint] = []
                for k in 0..<24 { pts.append(CGPoint(x: Double(k) * size.width / 23, y: size.height / 2 + sin(Double(k) * 0.6 + rng.next()) * size.height / 3)) }
                kind = .freehand(FreehandData(points: pts, pressures: []))
            case 5:
                kind = .text(TextData(text: "Item \(i)", autoWidth: true))
                style.fontSize = 16
            default: kind = .rectangle
            }
            var e = Element(kind: kind, frame: frame, rotation: rng.next() < 0.1 ? CGFloat(rng.range(-0.5, 0.5)) : 0, style: style,
                            seed: rng.nextUInt32())
            if e.isText { TextLayout.fit(&e) }
            if e.isLinear { e.setLinearWorldPoints(e.worldPoints) }
            elements.append(e)
        }
        var settings = DrawingSettings()
        settings.grid = .dots
        return Drawing(elements: elements, settings: settings)
    }
}
