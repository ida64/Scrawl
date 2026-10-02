import Foundation
import AppKit
import Testing
@testable import Scrawl

@Suite struct PersistenceTests {
    private func sampleDrawing() -> (Drawing, AssetStore) {
        SampleDocument.make()
    }

    @Test func roundTripPreservesEverything() throws {
        let (drawing, assets) = sampleDrawing()
        let wrapper = try DocumentCodec.fileWrapper(for: drawing, assets: assets, preview: nil, reusing: nil)
        let decoded = try DocumentCodec.decode(wrapper)
        #expect(decoded.warnings.isEmpty)
        #expect(decoded.drawing.elements.count == drawing.elements.count)
        for (a, b) in zip(drawing.elements, decoded.drawing.elements) {
            #expect(a.id == b.id)
            #expect(a.type == b.type)
            #expect(a.frame.isClose(to: b.frame, 0.001))
            #expect(abs(a.rotation - b.rotation) < 1e-9)
            #expect(a.style == b.style)
            #expect(a.groupIDs == b.groupIDs)
            #expect(a.frameID == b.frameID)
            #expect(a.seed == b.seed)
            #expect(a.isLocked == b.isLocked)
            #expect(a.linear?.startBinding?.elementID == b.linear?.startBinding?.elementID)
            #expect(a.textData == b.textData)
        }
        // Images are embedded, not referenced externally.
        let imageIDs = drawing.elements.compactMap { e -> String? in if case let .image(i) = e.kind { return i.assetID }; return nil }
        #expect(!imageIDs.isEmpty)
        for id in imageIDs { #expect(decoded.assets.asset(id)?.data == assets.asset(id)?.data) }
    }

    @Test func encodingIsDeterministic() throws {
        let (drawing, assets) = sampleDrawing()
        let a = try DocumentCodec.encodeJSON(drawing, assets: assets)
        let b = try DocumentCodec.encodeJSON(drawing, assets: assets)
        #expect(a == b)
        let json = String(decoding: a, as: UTF8.self)
        #expect(json.contains("\"version\" : 2"))
        #expect(json.contains("\"format\" : \"scrawl\""))
    }

    @Test func packageLayout() throws {
        let (drawing, assets) = sampleDrawing()
        let wrapper = try DocumentCodec.fileWrapper(for: drawing, assets: assets, preview: Data([1, 2, 3]), reusing: nil)
        let children = wrapper.fileWrappers ?? [:]
        #expect(children["document.json"] != nil)
        #expect(children["preview.png"] != nil)
        #expect((children["assets"]?.fileWrappers?.count ?? 0) >= 1)
    }

    @Test func unusedAssetsAreNotSaved() throws {
        let assets = AssetStore()
        let png = try #require(SampleDocument.makeSampleImage())
        _ = assets.add(data: png, fileExtension: "png")
        let wrapper = try DocumentCodec.fileWrapper(for: Drawing(elements: [rect(0, 0, 1, 1)]), assets: assets, preview: nil, reusing: nil)
        #expect(wrapper.fileWrappers?["assets"] == nil)
    }

    @Test func malformedElementsAreSkippedNotFatal() throws {
        let json = """
        {"format":"scrawl","version":1,"elements":[
          {"id":"\(UUID().uuidString)","type":"rectangle","x":0,"y":0,"width":10,"height":10},
          {"id":"bad","type":"hologram","x":0,"y":0,"width":10,"height":10},
          {"id":"\(UUID().uuidString)","type":"ellipse","x":"oops"},
          {"id":"\(UUID().uuidString)","type":"text","x":5,"y":5,"width":40,"height":20,"text":"ok","style":{"fontSize":"huge"}}
        ]}
        """
        let (drawing, _, warnings) = try DocumentCodec.decodeJSON(Data(json.utf8))
        #expect(drawing.elements.count == 1 || drawing.elements.count == 2)
        #expect(drawing.elements.first?.type == .rectangle)
        #expect(!warnings.isEmpty)
    }

    @Test func unknownStyleValuesFallBackToDefaults() throws {
        let json = """
        {"format":"scrawl","version":1,"elements":[{"id":"\(UUID().uuidString)","type":"rectangle","x":0,"y":0,"width":10,"height":10,
          "style":{"stroke":"not-a-color","fillStyle":"plaid","opacity":7,"strokeWidth":2}}]}
        """
        let (drawing, _, _) = try DocumentCodec.decodeJSON(Data(json.utf8))
        let s = try #require(drawing.elements.first?.style)
        #expect(s.strokeColor == .ink)
        #expect(s.fillStyle == ElementStyle().fillStyle)
        #expect(s.opacity == 1)
    }

    @Test func garbageIsAnUnderstandableError() {
        #expect(throws: DocumentError.self) { try DocumentCodec.decodeJSON(Data("not json".utf8)) }
        let wrapper = FileWrapper(directoryWithFileWrappers: [:])
        #expect(throws: DocumentError.self) { try DocumentCodec.decode(wrapper) }
    }

    @Test func danglingReferencesAreDropped() throws {
        let missing = UUID().uuidString
        let json = """
        {"format":"scrawl","version":1,"elements":[{"id":"\(UUID().uuidString)","type":"arrow","x":0,"y":0,"width":10,"height":0,
          "points":[[0,0],[10,0]],"startBinding":{"elementId":"\(missing)","anchor":[0.5,0.5]},"frameId":"\(missing)"}]}
        """
        let (drawing, _, _) = try DocumentCodec.decodeJSON(Data(json.utf8))
        #expect(drawing.elements.first?.linear?.startBinding == nil)
        #expect(drawing.elements.first?.frameID == nil)
    }

    @Test func missingAssetIsWarnedAndKept() throws {
        let img = Element(kind: .image(ImageData(assetID: "deadbeef", crop: CGRect(x: 0, y: 0, width: 1, height: 1))),
                          frame: CGRect(x: 0, y: 0, width: 10, height: 10), style: ElementStyle(), seed: 1)
        let wrapper = try DocumentCodec.fileWrapper(for: Drawing(elements: [img]), assets: AssetStore(), preview: nil, reusing: nil)
        let decoded = try DocumentCodec.decode(wrapper)
        #expect(decoded.drawing.elements.count == 1)
        #expect(!decoded.warnings.isEmpty)
    }

    @Test func migrationStepsRunInOrder() throws {
        // A hypothetical v1 → v2 step that renames "colour" to "stroke".
        var migrator = DocumentMigrator(steps: [:], targetVersion: 2)
        migrator.steps[1] = { json in
            guard var els = json["elements"] as? [[String: Any]] else { return }
            for i in els.indices {
                if var style = els[i]["style"] as? [String: Any], let c = style.removeValue(forKey: "colour") {
                    style["stroke"] = c
                    els[i]["style"] = style
                }
            }
            json["elements"] = els
        }
        let json = """
        {"format":"scrawl","version":1,"elements":[{"id":"\(UUID().uuidString)","type":"rectangle","x":0,"y":0,"width":1,"height":1,"style":{"colour":"#ff0000"}}]}
        """
        let (drawing, _, _) = try DocumentCodec.decodeJSON(Data(json.utf8), migrator: migrator)
        #expect(drawing.elements.first?.style.strokeColor == DrawingColor(hex: "#ff0000"))
    }

    @Test func standardMigrationRenamesV1RenderStyles() throws {
        let json = """
        {"format":"scrawl","version":1,"elements":[
          {"id":"\(UUID().uuidString)","type":"rectangle","x":0,"y":0,"width":1,"height":1,"style":{"render":"sketch"}},
          {"id":"\(UUID().uuidString)","type":"rectangle","x":0,"y":0,"width":1,"height":1,"style":{"render":"technical"}},
          {"id":"\(UUID().uuidString)","type":"rectangle","x":0,"y":0,"width":1,"height":1,"style":{"render":"clean"}}]}
        """
        let (drawing, _, warnings) = try DocumentCodec.decodeJSON(Data(json.utf8))
        #expect(drawing.elements.map(\.style.renderStyle) == [.ink, .precision, .precision])
        #expect(warnings.isEmpty)
    }

    @Test func namesHiddenAndTextMetricsRoundTrip() throws {
        var e = rect(0, 0, 10, 10)
        e.name = "Hero"
        e.isHidden = true
        e.style.fontName = "Menlo-Regular"
        e.style.lineHeight = 1.6
        let data = try DocumentCodec.encodeJSON(Drawing(elements: [e]))
        let (d, _, _) = try DocumentCodec.decodeJSON(data)
        #expect(d.elements.first?.name == "Hero")
        #expect(d.elements.first?.isHidden == true)
        #expect(d.elements.first?.style.fontName == "Menlo-Regular")
        #expect(d.elements.first?.style.lineHeight == 1.6)
    }

    @Test func newerVersionsOpenWithWarning() throws {
        let json = """
        {"format":"scrawl","version":99,"elements":[{"id":"\(UUID().uuidString)","type":"rectangle","x":0,"y":0,"width":1,"height":1,"futureField":true}]}
        """
        let (drawing, _, warnings) = try DocumentCodec.decodeJSON(Data(json.utf8))
        #expect(drawing.elements.count == 1)
        #expect(warnings.contains { $0.contains("newer") })
    }

    @Test func colorSerialization() {
        #expect(DrawingColor.parse("#FF0000")?.serialized == "#ff0000")
        #expect(DrawingColor.parse("#ff000080")?.serialized == "#ff000080")
        #expect(DrawingColor.parse("#abc")?.serialized == "#aabbcc")
        #expect(DrawingColor.parse("ink") == .ink)
        #expect(DrawingColor.parse("transparent") == .clear)
        #expect(DrawingColor.parse("zzz") == nil)
    }

    @Test func clipboardRoundTripsVectorsAndAssets() throws {
        let (drawing, assets) = sampleDrawing()
        let data = try #require(Clipboard.encode(drawing.elements, assets: assets))
        let (els, store) = try #require(Clipboard.decode(data))
        #expect(els.count == drawing.elements.count)
        #expect(store.ids == assets.ids)
    }

    @Test func clipboardWritesInteropTypes() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("scrawl-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        Clipboard.write([rect(0, 0, 40, 40), text("Copied text", at: CGPoint(x: 0, y: 60))], assets: AssetStore(), dark: false, to: pb)
        #expect(pb.data(forType: .scrawlElements) != nil)
        #expect(pb.data(forType: .png) != nil)
        #expect(pb.string(forType: .string) == "Copied text")
        if case let .elements(els, _) = Clipboard.read(pb) { #expect(els.count == 2) } else { Issue.record("expected elements") }
    }
}

@Suite struct ImportTests {
    @Test func excalidrawPrimitivesBecomeEditableElements() throws {
        let json = """
        {"type":"excalidraw","version":2,"elements":[
          {"id":"r1","type":"rectangle","x":0,"y":0,"width":100,"height":50,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#a5d8ff","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":["g1"],"roundness":{"type":3},"seed":5},
          {"id":"e1","type":"ellipse","x":300,"y":0,"width":80,"height":80,"angle":0.5,"strokeColor":"#e03131","backgroundColor":"transparent","fillStyle":"hachure","strokeWidth":1,"strokeStyle":"dashed","roughness":0,"opacity":50,"groupIds":["g1"]},
          {"id":"a1","type":"arrow","x":100,"y":25,"width":200,"height":15,"points":[[0,0],[200,15]],"startBinding":{"elementId":"r1","focus":0,"gap":4},"endBinding":{"elementId":"e1","focus":0,"gap":4},"endArrowhead":"triangle","groupIds":[]},
          {"id":"t1","type":"text","x":10,"y":100,"width":50,"height":25,"text":"Hello","fontSize":24,"fontFamily":3,"textAlign":"center","groupIds":[]},
          {"id":"d1","type":"freedraw","x":0,"y":200,"width":30,"height":30,"points":[[0,0],[10,10],[30,5]],"pressures":[0.5,0.6,0.7],"simulatePressure":false},
          {"id":"x1","type":"embeddable","x":0,"y":0,"width":10,"height":10},
          {"id":"del","type":"rectangle","x":0,"y":0,"width":10,"height":10,"isDeleted":true}
        ],"appState":{"viewBackgroundColor":"#ffffff","gridSize":null},"files":{}}
        """
        let result = try ExcalidrawImporter.importDrawing(Data(json.utf8))
        let els = result.drawing.elements
        #expect(els.count == 5)
        let r = try #require(els.first { $0.type == .rectangle })
        #expect(r.style.strokeColor == .ink)
        #expect(r.style.fillStyle == .solid)
        #expect(r.style.cornerRadius > 0)
        let e = try #require(els.first { $0.type == .ellipse })
        #expect(e.style.renderStyle == .precision)
        #expect(e.style.strokeStyle == .dashed)
        #expect(abs(e.style.opacity - 0.5) < 1e-9)
        #expect(r.outermostGroupID != nil && r.outermostGroupID == e.outermostGroupID)
        let a = try #require(els.first { $0.type == .arrow })
        #expect(a.linear?.startBinding?.elementID == r.id)
        #expect(a.linear?.endBinding?.elementID == e.id)
        #expect(a.style.endArrowhead == .triangle)
        let t = try #require(els.first { $0.isText })
        #expect(t.textData?.text == "Hello")
        #expect(t.style.fontFamily == .mono)
        let f = try #require(els.first { $0.type == .freehand })
        if case let .freehand(d) = f.kind { #expect(d.pressures.count == 3) }
        #expect(result.warnings.contains { $0.contains("embeddable") })
    }
}
