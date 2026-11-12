import XCTest
import SQLite3

final class TableControlsTests: XCTestCase {
    @MainActor
    func testRefreshShortcutAndButtonReloadExternalChanges() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "refresh.sqlite")
        try SQLiteFixture.create(at: file)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: file.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["refresh — refresh.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].click()
        let cell = window.staticTexts["grid-0-nazev"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &writer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(writer) }
        func waitForName(_ name: String) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: cell)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        }
        XCTAssertEqual(sqlite3_exec(writer, "UPDATE mesto SET nazev='Shortcut update' WHERE id=1", nil, nil, nil), SQLITE_OK)
        window.textFields["Search for field"].click()
        app.typeKey("r", modifierFlags: .command)
        waitForName("Shortcut update")
        XCTAssertEqual(sqlite3_exec(writer, "UPDATE mesto SET nazev='Button update' WHERE id=1", nil, nil, nil), SQLITE_OK)
        window.buttons["Refresh Data"].click()
        waitForName("Button update")
        cell.doubleClick(); app.typeText("Local draft"); app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(window.buttons["Preview Changes"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["Refresh Data"].isEnabled)
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue((cell.value as? String)?.contains("Local draft") == true)
    }

    @MainActor
    func testApplyOneFilterAndCommitOnTabClose() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: dir) }
        let db = dir.appending(path: "filters.sqlite")
        try SQLiteFixture.create(at: db)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString); app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["filters — filters.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        let cell = window.staticTexts["grid-0-nazev"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5)); cell.click()
        app.typeKey("f", modifierFlags: .command)
        let fields = window.textFields.matching(identifier: "Filter Value")
        fields.element(boundBy: 0).replaceText(with: "1")
        window.buttons["Add Condition"].click(); fields.element(boundBy: 1).replaceText(with: "2")
        window.buttons.matching(identifier: "Apply condition").element(boundBy: 0).click()
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "1 of 1 row")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cell.value as? String, "Brno")
        fields.element(boundBy: 1).click(); app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(window.staticTexts["0 of 0 rows"].waitForExistence(timeout: 5))
        XCTAssertEqual(fields.count, 2)
        window.buttons["Unset"].click(); XCTAssertTrue(window.staticTexts["3 of 3 rows"].waitForExistence(timeout: 5))
        cell.click(); window.buttons["Edit Row"].click()
        app.textFields["edit-nazev"].replaceText(with: "Saved before closing")
        app.buttons["Stage Changes"].click(); window.buttons["Close Tab"].click()
        app.buttons["Review and Commit…"].click()
        XCTAssertTrue(app.staticTexts["changePreviewSQL"].waitForExistence(timeout: 5))
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(db.path, &writer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        app.buttons["Commit Changes"].click()
        let locked = app.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'database is locked'")).firstMatch
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["changePreviewSQL"].exists)
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        app.buttons["Commit Changes"].click()
        XCTAssertTrue(window.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        XCTAssertTrue(window.staticTexts["Saved before closing"].firstMatch.waitForExistence(timeout: 5))
    }
}
