import AppKit
import Foundation
import Testing
@testable import Scrawl

/// Workspace operations driven by the inspector, layers sidebar, menus and palette.
@Suite struct EditorWorkspaceTests {
    private func makeEditor(_ elements: [Element]) -> (Editor, UndoManager) {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let editor = Editor(scene: Scene(drawing: Drawing(elements: elements)), assets: AssetStore(), undoManager: undo)
        return (editor, undo)
    }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func renameAndUndo() {
        let r = rect(0, 0, 10, 10)
        let (editor, undo) = makeEditor([r])
        step(undo) { editor.rename(r.id, to: "  Hero  ") }
        #expect(editor.scene.element(r.id)?.name == "Hero")
        #expect(editor.scene.element(r.id)?.displayName == "Hero")
        undo.undo()
        #expect(editor.scene.element(r.id)?.name == nil)
    }

    @Test func hiddenElementsAreSkippedByExportAndHitTesting() {
        var r = rect(0, 0, 10, 10)
        r.isHidden = true
        let visible = rect(100, 0, 10, 10)
        let scene = Scene(drawing: Drawing(elements: [r, visible]))
        #expect(ExportService.content(for: .drawing, scene: scene).elements.map(\.id) == [visible.id])
        let (editor, undo) = makeEditor([rect(0, 0, 10, 10)])
        let id = editor.scene.elements[0].id
        editor.select([id])
        step(undo) { editor.toggleHiddenSelection() }
        #expect(editor.scene.element(id)?.isHidden == true)
        #expect(editor.selection.isEmpty)
        step(undo) { editor.showAllHidden() }
        #expect(editor.scene.element(id)?.isHidden == false)
    }

    @Test func moveLayersAboveTarget() {
        let a = rect(0, 0, 1, 1), b = rect(0, 0, 1, 1), c = rect(0, 0, 1, 1)
        let (editor, undo) = makeEditor([a, b, c])
        step(undo) { editor.moveLayers([a.id], above: c.id) }
        #expect(editor.scene.elements.map(\.id) == [b.id, c.id, a.id])
        step(undo) { editor.moveLayers([a.id], above: nil) }
        #expect(editor.scene.elements.map(\.id) == [a.id, b.id, c.id])
        undo.undo()
        #expect(editor.scene.elements.map(\.id) == [b.id, c.id, a.id])
    }

    @Test func inspectorGeometryFields() {
        let r = rect(0, 0, 100, 50)
        let (editor, undo) = makeEditor([r])
        editor.select([r.id])
        step(undo) { editor.setGeometry(x: 20, y: 30) }
        #expect(editor.scene.element(r.id)?.frame.origin == CGPoint(x: 20, y: 30))
        step(undo) { editor.setGeometry(width: 200, keepAspect: true) }
        #expect(editor.scene.element(r.id)?.frame.size == CGSize(width: 200, height: 100))
        step(undo) { editor.setRotation(degrees: 90) }
        #expect(abs((editor.scene.element(r.id)?.rotation ?? 0) - .pi / 2) < 1e-9)
        undo.undo(); undo.undo(); undo.undo()
        #expect(editor.scene.element(r.id) == r)
    }

    @Test func multiSelectionGeometryScalesTogether() {
        let a = rect(0, 0, 50, 50), b = rect(150, 50, 50, 50)
        let (editor, undo) = makeEditor([a, b])
        editor.select([a.id, b.id])
        #expect(editor.summary.geometry == CGRect(x: 0, y: 0, width: 200, height: 100))
        step(undo) { editor.setGeometry(width: 400, keepAspect: true) }
        #expect(editor.scene.element(b.id)?.frame.isClose(to: CGRect(x: 300, y: 100, width: 100, height: 100)) == true)
    }

    @Test func convertShapesAndConnectors() {
        let r = rect(0, 0, 10, 10)
        var l = arrow(.zero, CGPoint(x: 10, y: 0))
        l.kind = .line(l.linear!)
        let (editor, undo) = makeEditor([r, l])
        editor.select([r.id])
        step(undo) { editor.convert(to: .ellipse) }
        #expect(editor.scene.element(r.id)?.type == .ellipse)
        editor.select([l.id])
        step(undo) { editor.convert(to: .arrow) }
        #expect(editor.scene.element(l.id)?.type == .arrow)
        #expect(editor.scene.element(l.id)?.style.endArrowhead != Arrowhead.none)
    }

    @Test func frameSelectionWrapsAndAdopts() {
        let a = rect(0, 0, 10, 10), b = rect(100, 100, 10, 10)
        let (editor, undo) = makeEditor([a, b])
        editor.select([a.id, b.id])
        step(undo) { editor.frameSelection() }
        let frame = editor.scene.elements.first
        #expect(frame?.isFrame == true)
        #expect(frame.map { $0.frame.contains(CGRect(x: 0, y: 0, width: 110, height: 110)) } == true)
        #expect(editor.scene.element(a.id)?.frameID == frame?.id)
        undo.undo()
        #expect(editor.scene.count == 2)
    }

    @Test func copyAndPasteStyle() {
        var a = rect(0, 0, 10, 10)
        a.style.strokeColor = DrawingColor(hex: "#ff0000")
        a.style.renderStyle = .ink
        let b = rect(20, 0, 10, 10)
        let (editor, undo) = makeEditor([a, b])
        editor.select([a.id])
        editor.copyStyle()
        editor.select([b.id])
        #expect(editor.canPasteStyle)
        step(undo) { editor.pasteStyle() }
        #expect(editor.scene.element(b.id)?.style.strokeColor == DrawingColor(hex: "#ff0000"))
        #expect(editor.scene.element(b.id)?.style.renderStyle == .ink)
    }

    @Test func layerTreeNestsFrameChildren() {
        let f = Element(kind: .frame(FrameData(name: "F")), frame: CGRect(x: 0, y: 0, width: 100, height: 100), style: ElementStyle(), seed: 1)
        var child = rect(10, 10, 10, 10)
        child.frameID = f.id
        let loose = rect(500, 500, 10, 10)
        let scene = Scene(drawing: Drawing(elements: [f, child, loose]))
        let nodes = LayerNode.build(scene, filter: "")
        #expect(nodes.map(\.id) == [loose.id, f.id])
        #expect(nodes.last?.children?.map(\.id) == [child.id])
        #expect(LayerNode.build(scene, filter: "zzz").isEmpty)
    }

    @Test func softModeRoundsShapes() {
        var r = rect(0, 0, 100, 60)
        r.style.cornerRadius = 0
        r.style.renderStyle = .soft
        #expect(ElementGeometry.clampedRadius(r) > 10)
        r.style.renderStyle = .precision
        #expect(ElementGeometry.clampedRadius(r) == 0)
    }

    @Test func paletteSearchFindsTypedPhrases() {
        #expect(PaletteCommands.score("bring front", "Bring to Front") != nil)
        #expect(PaletteCommands.score("zoom selection", "Zoom to Selection") != nil)
        #expect(PaletteCommands.score("export svg", "Export as SVG… export svg") != nil)
        #expect(PaletteCommands.score("xyz", "Zoom to Fit") == nil)
    }
}
