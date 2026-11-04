import XCTest

final class WorkspaceInteractionTests: XCTestCase {
    /// A populated workspace with a private database; no user profile is opened.
    @MainActor private func inCatalog(_ run: (XCUIElement) throws -> Void) throws {
        let app = XCUIApplication(), fm = FileManager.default
        let p = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: p, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: p) }
        let db = p.appending(path: "qa.sqlite")
        try SQLiteFixture.create(at: db)
        let profile: [String: Any] = ["id": UUID().uuidString, "name": "QA", "driver": "SQLite",
            "filePath": db.path, "host": "", "port": "", "user": "", "database": "", "environment": "local",
            "socketPath": "", "usesSocket": false, "verifyTLS": false, "caPath": "", "rememberPassword": false]
        try JSONSerialization.data(withJSONObject: [["id": UUID().uuidString, "name": "Fixtures", "connections": [profile]]])
            .write(to: p.appending(path: "connections.json"))
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = p.path
        app.launch()
        let saved = app.windows["Saved Connections"].staticTexts["QA"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.doubleClick()
        let window = app.windows["QA — qa.sqlite"]
        let city = window.staticTexts["mesto"]
        XCTAssertTrue(city.waitForExistence(timeout: 5)); city.click()
        XCTAssertTrue(window.staticTexts["grid-0-nazev"].waitForExistence(timeout: 4))
        try run(window)
    }

    @MainActor func testDraggingConsoleResizesBothWaysAndSurvivesToggling() throws {
        continueAfterFailure = false
        try inCatalog { w in
            let console = w.scrollViews["SQL Console"]
            @MainActor func drag(_ dy: CGFloat) {
                let edge = console.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0))
                    .withOffset(CGVector(dx: 0, dy: -2))
                edge.click(forDuration: 0.18, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: dy)))
            }
            let initial = console.frame.height
            let firstRow = w.staticTexts["grid-0-nazev"], footer = w.radioButtons["Data"]
            let gridInitially = footer.frame.minY - firstRow.frame.minY
            drag(-90)
            let expanded = console.frame.height
            XCTAssertGreaterThan(expanded, initial + 65)
            XCTAssertLessThan(footer.frame.minY - firstRow.frame.minY, gridInitially - 65)
            drag(45)
            let adjusted = console.frame.height
            XCTAssertLessThan(adjusted, expanded - 25)
            w.buttons["SQL Console"].click()
            XCTAssertTrue(console.waitForNonExistence(timeout: 3))
            w.buttons["SQL Console"].click()
            XCTAssertTrue(console.waitForExistence(timeout: 3))
            XCTAssertEqual(console.frame.height, adjusted, accuracy: 4)
        }
    }

    @MainActor func testCloseOnInactiveTabPreservesCurrentTableAndDirtyQuery() throws {
        continueAfterFailure = false
        try inCatalog { w in
            w.staticTexts["zeme"].click()
            XCTAssertTrue(w.staticTexts["grid-0-kod"].waitForExistence(timeout: 4))
            w.buttons["New Query"].click()
            w.textViews["SQL Editor"].replaceText(with: "SELECT 42;")
            w.buttons["zeme"].click()
            let closeCity = w.buttons["Close mesto"]
            XCTAssertTrue(closeCity.isHittable)
            closeCity.click()
            XCTAssertFalse(w.buttons["mesto"].exists)
            XCTAssertTrue(w.staticTexts["grid-0-kod"].exists)
            w.buttons["Close Query 1"].click()
            let app = XCUIApplication()
            XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 4))
            app.buttons["Keep Editing"].click()
            XCTAssertTrue(w.staticTexts["grid-0-kod"].exists)
            w.buttons["Query 1"].click()
            XCTAssertEqual(w.textViews["SQL Editor"].value as? String, "SELECT 42;")
        }
    }
}
