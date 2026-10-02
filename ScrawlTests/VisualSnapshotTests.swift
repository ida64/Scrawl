import AppKit
import Foundation
import Testing
@testable import Scrawl

/// Writes renders of the sample drawing for visual review (to the test host's temp directory).
@Suite struct VisualSnapshotTests {
    @Test func renderSampleDrawing() throws {
        let (drawing, assets) = SampleDocument.make()
        let scene = Scene(drawing: drawing)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScrawlSnapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [true, false] {
            var o = ExportOptions()
            o.dark = dark
            o.scale = 1
            let png = try #require(ExportService.export(.drawing, format: .png, scene: scene, assets: assets, options: o))
            try png.write(to: dir.appendingPathComponent(dark ? "sample-dark.png" : "sample-light.png"))
        }
        let svg = try #require(ExportService.export(.drawing, format: .svg, scene: scene, assets: assets, options: ExportOptions()))
        try svg.write(to: dir.appendingPathComponent("sample.svg"))
        print("SNAPSHOT_DIR=\(dir.path)")
    }
}
