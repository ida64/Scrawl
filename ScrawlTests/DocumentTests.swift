import AppKit
import UniformTypeIdentifiers
import Foundation
import Testing
@testable import Scrawl

@Suite struct DocumentTests {
    @Test func saveCloseReopenThroughNSDocument() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScrawlTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Roundtrip.scrawl")

        let doc = ScrawlDocument()
        let (drawing, assets) = SampleDocument.make()
        doc.assets.merge(assets)
        doc.scene.load(drawing)
        try await doc.save(to: url, ofType: UTType.scrawlDrawing.identifier, for: .saveOperation)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("document.json").path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("preview.png").path))

        let reopened = try ScrawlDocument(contentsOf: url, ofType: UTType.scrawlDrawing.identifier)
        #expect(reopened.scene.count == drawing.elements.count)
        #expect(reopened.scene.elements.map(\.id) == drawing.elements.map(\.id))
        #expect(reopened.assets.ids == assets.ids)

        // Saving again over the existing package works and keeps assets.
        reopened.scene.update(reopened.scene.elements[3].id) { $0.translate(by: CGPoint(x: 5, y: 5)) }
        try await reopened.save(to: url, ofType: UTType.scrawlDrawing.identifier, for: .saveOperation)
        let again = try ScrawlDocument(contentsOf: url, ofType: UTType.scrawlDrawing.identifier)
        #expect(again.scene.elements[3].frame.origin == reopened.scene.elements[3].frame.origin)
        #expect(again.assets.ids == assets.ids)
    }

    @Test func corruptPackageThrowsReadableError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Corrupt-\(UUID()).scrawl", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ truncated".utf8).write(to: dir.appendingPathComponent("document.json"))
        do {
            _ = try ScrawlDocument(contentsOf: dir, ofType: UTType.scrawlDrawing.identifier)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("damaged") || error.localizedDescription.contains("couldn’t"))
        }
    }
}
