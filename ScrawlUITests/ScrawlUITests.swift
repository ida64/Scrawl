import XCTest

/// End-to-end workflow: draw, type, move, undo/redo, command palette, save, close, reopen.
final class ScrawlUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshDrawing", "-ApplePersistenceIgnoreState", "YES", "-launchBehavior", "welcome"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private var canvas: XCUIElement { app.windows.firstMatch.descendants(matching: .any)["canvas"] }

    private func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func drag(from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat)) {
        point(a.0, a.1).press(forDuration: 0.05, thenDragTo: point(b.0, b.1))
    }

    private func expectValue(_ prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value BEGINSWITH %@", prefix)
        let exp = expectation(for: predicate, evaluatedWith: canvas)
        wait(for: [exp], timeout: 3)
    }

    func testCoreWorkflowSaveAndReopen() throws {
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.click()

        // Rectangle with the keyboard-selected tool.
        app.typeKey("r", modifierFlags: [])
        drag(from: (0.30, 0.40), to: (0.45, 0.60))
        expectValue("1 element")

        // Ellipse and an arrow between the two shapes.
        app.typeKey("o", modifierFlags: [])
        drag(from: (0.60, 0.40), to: (0.75, 0.60))
        app.typeKey("a", modifierFlags: [])
        drag(from: (0.40, 0.50), to: (0.67, 0.50))
        expectValue("3 elements")

        // Text.
        app.typeKey("t", modifierFlags: [])
        point(0.35, 0.80).click()
        app.typeText("Hello Scrawl")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        expectValue("4 elements")

        // Select and move the rectangle; one undo reverts the whole drag.
        app.typeKey("v", modifierFlags: [])
        drag(from: (0.30, 0.45), to: (0.20, 0.30))
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command) // undo text
        expectValue("3 elements")
        app.typeKey("z", modifierFlags: [.command, .shift])
        expectValue("4 elements")

        // Duplicate, then delete the duplicate.
        point(0.30, 0.45).click()
        app.typeKey("d", modifierFlags: .command)
        expectValue("5 elements")
        app.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        expectValue("4 elements")

        // Command palette.
        app.typeKey("k", modifierFlags: .command)
        let search = app.windows.firstMatch.textFields["Search commands"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.typeText("zoom to fit\r")
        XCTAssertFalse(search.waitForExistence(timeout: 1) && search.isHittable)

        // Save to a temp location, close, reopen through Open Recent.
        let name = "UITest-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory.path
        app.typeKey("s", modifierFlags: .command)
        let sheet = app.windows.firstMatch.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        app.typeKey("a", modifierFlags: .command)
        app.typeText(name)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(dir + "\r")
        sleep(1)
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let saved = URL(fileURLWithPath: dir).appendingPathComponent(name + ".scrawl")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: saved.path) && Date() < deadline { usleep(200_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent("document.json").path))
        defer { try? FileManager.default.removeItem(at: saved) }

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(canvas.waitForNonExistence(timeout: 3))

        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["Open Recent"].hover()
        let recent = app.menuBars.menuItems[name + ".scrawl"].exists ? app.menuBars.menuItems[name + ".scrawl"] : app.menuBars.menuItems[name]
        XCTAssertTrue(recent.waitForExistence(timeout: 2))
        recent.click()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        expectValue("4 elements")
    }
}
