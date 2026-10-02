import Foundation
import CoreGraphics
import Testing
@testable import Scrawl

@Suite struct CommandTests {
    @Test func createUndoRedo() {
        let h = Harness()
        let r = rect(0, 0, 10, 10)
        h.perform(CreateElementsCommand(elements: [r]))
        #expect(h.scene.count == 1)
        #expect(h.selection == [r.id])
        h.undo.undo()
        #expect(h.scene.count == 0)
        #expect(h.selection.isEmpty)
        h.undo.redo()
        #expect(h.scene.element(r.id) == r)
    }

    @Test func deleteRestoresZOrder() {
        let a = rect(0, 0, 10, 10), b = rect(20, 0, 10, 10), c = rect(40, 0, 10, 10)
        let h = Harness([a, b, c])
        h.perform(DeleteElementsCommand(ids: [b.id]))
        #expect(h.scene.elements.map(\.id) == [a.id, c.id])
        h.undo.undo()
        #expect(h.scene.elements.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func moveIsOneUndoStep() {
        let a = rect(0, 0, 10, 10)
        let h = Harness([a])
        h.interactive("Move") {
            for _ in 0..<100 { SceneOps.translate([a.id], by: CGPoint(x: 1, y: 2), in: h.scene) }
        }
        #expect(h.scene.element(a.id)?.frame.origin == CGPoint(x: 100, y: 200))
        h.undo.undo()
        #expect(h.scene.element(a.id)?.frame.origin == .zero)
        #expect(!h.undo.canUndo)
    }

    @Test func cancelledInteractionRevertsWithoutUndo() {
        let a = rect(0, 0, 10, 10)
        let h = Harness([a])
        h.commands.beginInteractive("Move")
        SceneOps.translate([a.id], by: CGPoint(x: 50, y: 0), in: h.scene)
        h.commands.cancelInteractive()
        #expect(h.scene.element(a.id)?.frame.origin == .zero)
        #expect(!h.undo.canUndo)
    }

    @Test func lockedElementsDontMoveOrDelete() {
        var a = rect(0, 0, 10, 10)
        a.isLocked = true
        let h = Harness([a])
        h.perform(MoveElementsCommand(ids: [a.id], delta: CGPoint(x: 5, y: 5)))
        h.perform(DeleteElementsCommand(ids: [a.id]))
        #expect(h.scene.element(a.id)?.frame.origin == .zero)
    }

    @Test func styleChangeUndo() {
        let a = rect(0, 0, 10, 10)
        let h = Harness([a])
        h.perform(ChangeStyleCommand(ids: [a.id]) { $0.strokeWidth = 6; $0.fillColor = DrawingColor(hex: "#123456") })
        #expect(h.scene.element(a.id)?.style.strokeWidth == 6)
        h.undo.undo()
        #expect(h.scene.element(a.id)?.style == a.style)
    }

    @Test func textEditUndoRefits() {
        let t = text("Hi", at: .zero)
        let h = Harness([t])
        h.perform(EditTextCommand(id: t.id, text: "Hello, wider world"))
        let edited = h.scene.element(t.id)
        #expect(edited?.textData?.text == "Hello, wider world")
        #expect((edited?.frame.width ?? 0) > t.frame.width)
        h.undo.undo()
        #expect(h.scene.element(t.id) == t)
    }

    @Test func rotateAndUndo() {
        let a = rect(0, 0, 100, 50)
        let h = Harness([a])
        h.perform(RotateElementsCommand(ids: [a.id], angle: .pi / 2))
        #expect(abs((h.scene.element(a.id)?.rotation ?? 0) - .pi / 2) < 1e-9)
        h.undo.undo()
        #expect(h.scene.element(a.id)?.rotation == 0)
    }

    @Test func resizeCommandScalesLinearPoints() {
        let l = arrow(.zero, CGPoint(x: 100, y: 50))
        let h = Harness([l])
        h.perform(ResizeElementsCommand(frames: [l.id: CGRect(x: 0, y: 0, width: 200, height: 100)]))
        #expect(h.scene.element(l.id)?.worldPoints.last?.isClose(to: CGPoint(x: 200, y: 100)) == true)
        h.undo.undo()
        #expect(h.scene.element(l.id) == l)
    }

    @Test func pasteCopiesGetFreshIDsAndRemappedBindings() {
        let a = rect(0, 0, 50, 50), b = rect(200, 0, 50, 50)
        let arr = arrow(CGPoint(x: 55, y: 25), CGPoint(x: 195, y: 25),
                        start: ConnectorBinding(elementID: a.id, anchor: CGPoint(x: 1, y: 0.5)),
                        end: ConnectorBinding(elementID: b.id, anchor: CGPoint(x: 0, y: 0.5)))
        let h = Harness([a, b, arr])
        var ids: [ElementID] = []
        h.perform(SimpleCommand(name: "Paste") { scene in
            ids = SceneOps.insertCopies(of: [a, b, arr], offset: CGPoint(x: 10, y: 10), in: scene)
            return Set(ids)
        })
        #expect(h.scene.count == 6)
        #expect(Set(ids).isDisjoint(with: [a.id, b.id, arr.id]))
        let copiedArrow = h.scene.elements(Set(ids)).first { $0.isLinear }
        let binding = copiedArrow?.linear?.startBinding?.elementID
        #expect(binding != nil && binding != a.id && ids.contains(binding!))
        h.undo.undo()
        #expect(h.scene.count == 3)
    }
}

@Suite struct ArrangeTests {
    @Test func groupingSelectsAsUnitAndUndoes() {
        let a = rect(0, 0, 10, 10), b = rect(50, 0, 10, 10), c = rect(100, 0, 10, 10)
        let h = Harness([a, b, c])
        h.perform(GroupElementsCommand(ids: [a.id, c.id]))
        let g = h.scene.element(a.id)?.outermostGroupID
        #expect(g != nil && g == h.scene.element(c.id)?.outermostGroupID)
        #expect(SceneOps.expandToGroups([a.id], in: h.scene) == [a.id, c.id])
        // Group members become contiguous in z-order.
        let order = h.scene.elements.map(\.id)
        #expect(abs(order.firstIndex(of: a.id)! - order.firstIndex(of: c.id)!) == 1)
        h.undo.undo()
        #expect(h.scene.element(a.id)?.groupIDs.isEmpty == true)
        #expect(h.scene.elements.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func nestedGroupsUngroupOneLevel() {
        let a = rect(0, 0, 10, 10), b = rect(50, 0, 10, 10), c = rect(100, 0, 10, 10)
        let h = Harness([a, b, c])
        h.perform(GroupElementsCommand(ids: [a.id, b.id]))
        h.perform(GroupElementsCommand(ids: [a.id, c.id]))
        #expect(h.scene.element(a.id)?.groupIDs.count == 2)
        #expect(SceneOps.expandToGroups([b.id], in: h.scene) == [a.id, b.id, c.id])
        h.perform(UngroupElementsCommand(ids: [a.id, b.id, c.id]))
        #expect(SceneOps.expandToGroups([a.id], in: h.scene) == [a.id, b.id])
    }

    @Test func zOrderOperations() {
        let ids = (0..<5).map { _ in UUID() }
        let m: Set<ElementID> = [ids[1]]
        #expect(ReorderCommand.reorder(ids, moving: m, .bringToFront) == [ids[0], ids[2], ids[3], ids[4], ids[1]])
        #expect(ReorderCommand.reorder(ids, moving: m, .sendToBack) == [ids[1], ids[0], ids[2], ids[3], ids[4]])
        #expect(ReorderCommand.reorder(ids, moving: m, .bringForward) == [ids[0], ids[2], ids[1], ids[3], ids[4]])
        #expect(ReorderCommand.reorder(ids, moving: m, .sendBackward) == [ids[1], ids[0], ids[2], ids[3], ids[4]])
        #expect(ReorderCommand.reorder(ids, moving: [ids[4]], .bringForward) == ids)
        let multi: Set<ElementID> = [ids[0], ids[2]]
        #expect(ReorderCommand.reorder(ids, moving: multi, .bringToFront) == [ids[1], ids[3], ids[4], ids[0], ids[2]])
    }

    @Test func reorderUndo() {
        let a = rect(0, 0, 10, 10), b = rect(5, 5, 10, 10)
        let h = Harness([a, b])
        h.perform(ReorderCommand(ids: [a.id], action: .bringToFront))
        #expect(h.scene.elements.map(\.id) == [b.id, a.id])
        h.undo.undo()
        #expect(h.scene.elements.map(\.id) == [a.id, b.id])
    }

    @Test func alignLeftAndDistribute() {
        let a = rect(10, 0, 20, 20), b = rect(50, 40, 40, 20), c = rect(300, 80, 20, 20)
        let h = Harness([a, b, c])
        h.perform(AlignCommand(ids: [a.id, b.id, c.id], action: .left))
        #expect(h.scene.elements.allSatisfy { $0.frame.minX == 10 })
        h.undo.undo()
        h.perform(AlignCommand(ids: [a.id, b.id, c.id], action: .distributeH))
        let xs = h.scene.elements.map(\.frame)
        // Total span 10…320 = 310, widths 80 → gap 115.
        #expect(abs(xs[1].minX - (30 + 115)) < 1e-9)
        #expect(xs[0].minX == 10 && xs[2].minX == 300)
    }

    @Test func alignTreatsGroupsAsUnits() {
        var a = rect(0, 0, 10, 10), b = rect(100, 0, 10, 10)
        let g = UUID()
        a.groupIDs = [g]; b.groupIDs = [g]
        let c = rect(0, 50, 10, 10)
        let h = Harness([a, b, c])
        h.perform(AlignCommand(ids: [a.id, b.id, c.id], action: .right))
        // Group (0…110) and c align to right edge 110: group stays, c moves to x = 100.
        #expect(h.scene.element(a.id)?.frame.minX == 0)
        #expect(h.scene.element(b.id)?.frame.minX == 100)
        #expect(h.scene.element(c.id)?.frame.minX == 100)
    }

    @Test func framesCarryChildrenAndDeleteThem() {
        let f = Element(kind: .frame(FrameData(name: "F")), frame: CGRect(x: 0, y: 0, width: 300, height: 300), style: ElementStyle(), seed: 1)
        let inside = rect(10, 10, 20, 20), outside = rect(500, 500, 10, 10)
        let h = Harness([inside, outside])
        h.perform(CreateElementsCommand(elements: [f]))
        #expect(h.scene.element(inside.id)?.frameID == f.id)
        #expect(h.scene.element(outside.id)?.frameID == nil)
        #expect(h.scene.elements.first?.id == f.id) // frames go to the back
        h.perform(MoveElementsCommand(ids: [f.id], delta: CGPoint(x: 100, y: 0)))
        #expect(h.scene.element(inside.id)?.frame.minX == 110)
        h.perform(DeleteElementsCommand(ids: [f.id]))
        #expect(h.scene.element(inside.id) == nil)
        h.undo.undo()
        #expect(h.scene.element(inside.id)?.frameID == f.id)
    }
}
