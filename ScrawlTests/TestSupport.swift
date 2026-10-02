import CoreGraphics
import Foundation
@testable import Scrawl

/// Builds a scene plus command manager wired to a real UndoManager, as a document would.
final class Harness {
    let scene: Scene
    let undo = UndoManager()
    let commands: CommandManager
    var selection: Set<ElementID> = []

    init(_ elements: [Element] = []) {
        scene = Scene(drawing: Drawing(elements: elements))
        undo.groupsByEvent = false
        commands = CommandManager(scene: scene)
        commands.undoManager = undo
        commands.getSelection = { [unowned self] in self.selection }
        commands.setSelection = { [unowned self] in self.selection = $0 }
    }

    /// Mimics one run-loop event: each perform becomes its own undo group.
    @discardableResult
    func perform(_ c: SceneCommand) -> Bool {
        undo.beginUndoGrouping()
        defer { undo.endUndoGrouping() }
        return commands.perform(c)
    }

    func interactive(_ name: String, _ body: () -> Void) {
        undo.beginUndoGrouping()
        commands.beginInteractive(name)
        body()
        commands.endInteractive()
        undo.endUndoGrouping()
    }
}

func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, fill: DrawingColor = .clear, id: UUID = UUID()) -> Element {
    var s = ElementStyle()
    s.fillColor = fill
    return Element(id: id, kind: .rectangle, frame: CGRect(x: x, y: y, width: w, height: h), style: s, seed: 7)
}

func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Element {
    Element(kind: .ellipse, frame: CGRect(x: x, y: y, width: w, height: h), style: ElementStyle(), seed: 8)
}

func arrow(_ a: CGPoint, _ b: CGPoint, start: ConnectorBinding? = nil, end: ConnectorBinding? = nil) -> Element {
    var e = Element(kind: .arrow(LinearData(points: [], startBinding: start, endBinding: end)), frame: .zero, style: ElementStyle(), seed: 9)
    e.setLinearWorldPoints([a, b])
    return e
}

func text(_ s: String, at p: CGPoint) -> Element {
    var e = Element(kind: .text(TextData(text: s, autoWidth: true)), frame: CGRect(origin: p, size: .zero), style: ElementStyle(), seed: 10)
    TextLayout.fit(&e)
    return e
}

extension CGPoint {
    func isClose(to p: CGPoint, _ eps: CGFloat = 0.001) -> Bool { abs(x - p.x) < eps && abs(y - p.y) < eps }
}

extension CGRect {
    func isClose(to r: CGRect, _ eps: CGFloat = 0.001) -> Bool {
        abs(minX - r.minX) < eps && abs(minY - r.minY) < eps && abs(width - r.width) < eps && abs(height - r.height) < eps
    }
}
