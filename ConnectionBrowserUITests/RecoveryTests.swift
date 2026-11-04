import XCTest

final class RecoveryTests: XCTestCase {
    @MainActor
    func testReopeningAProfileRecoversPanelLayoutAndSQLTextWithoutRunningIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: dir) }
        let db = dir.appending(path: "recovery.sqlite")
        try SQLiteFixture.create(at: db)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString); app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["recovery — recovery.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 6))
        window.buttons["Row Detail"].click(); XCTAssertFalse(window.textFields["Search for field"].exists)
        window.buttons["New Query"].click()
        let editor = window.textViews["SQL Editor"], sql = "SELECT 'restored buffer' AS value;"
        editor.replaceText(with: sql)
        let persisted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let files = (try? fm.contentsOfDirectory(at: dir.appending(path: "Queries"), includingPropertiesForKeys: nil)) ?? []
            return files.contains { (try? String(contentsOf: $0, encoding: .utf8).contains(sql)) == true }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 6), .completed)
        app.terminate(); app.launch()
        app.windows["Saved Connections"].staticTexts["recovery"].doubleClick()
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.textFields["Search for field"].exists)
        XCTAssertFalse(editor.exists)
        app.menuBars.menuBarItems["File"].click(); app.menuItems["Recover SQL Draft…"].click()
        app.buttons["Recover Text"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 4)); XCTAssertEqual(editor.value as? String, sql)
        XCTAssertFalse(window.staticTexts["restored buffer"].exists)
        window.buttons["Run Current"].click(); XCTAssertTrue(window.staticTexts["restored buffer"].firstMatch.waitForExistence(timeout: 5))
        window.buttons["Close Tab"].click(); app.buttons["Discard and Close"].click()
        app.menuBars.menuBarItems["File"].click(); app.menuItems["Recover SQL Draft…"].click()
        XCTAssertTrue(app.staticTexts["No Recoverable Drafts"].waitForExistence(timeout: 4))
    }
}
