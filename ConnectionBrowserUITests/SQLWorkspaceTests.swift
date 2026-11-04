import SQLite3
import XCTest

final class SQLWorkspaceTests: XCTestCase {
    @MainActor
    func testQueryTabsKeepTheirOwnResultsAndHistoryCanReopenSQL() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "notebook.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
        sqlite3_close(handle)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        app.buttons["New Connection"].click()
        XCTAssertTrue(app.radioButtons["SQLite"].waitForExistence(timeout: 4))
        app.radioButtons["SQLite"].click()
        app.textFields["Connection Name"].replaceText(with: "Notebook")
        app.textFields["Database File"].replaceText(with: file.path)
        app.buttons["Save and Connect"].click()
        let window = app.windows["Notebook — notebook.sqlite"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.buttons["New Query"].click()
        let editor = window.textViews["SQL Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 4))
        let first = "SELECT 'First' AS label UNION ALL SELECT 'Second';"
        editor.replaceText(with: first)
        window.buttons["Run Current"].click()
        XCTAssertTrue(window.staticTexts["Second"].waitForExistence(timeout: 4))
        window.buttons["New Query"].click()
        editor.replaceText(with: "SELECT * FROM no_such_table;")
        window.buttons["Run Current"].click()
        XCTAssertTrue(window.staticTexts["queryError"].waitForExistence(timeout: 4))
        XCTAssertFalse(window.staticTexts["Second"].exists)
        window.buttons["Query 1"].click()
        XCTAssertTrue(window.staticTexts["First"].waitForExistence(timeout: 4))
        XCTAssertEqual(editor.value as? String, first)
        window.staticTexts["First"].firstMatch.click()
        let detail = window.staticTexts["row-detail-header"]
        XCTAssertTrue(detail.exists)
        window.buttons["Row Detail"].click()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 3))
        window.buttons["Item List"].click()
        XCTAssertFalse(window.radioButtons["History"].exists)
        window.buttons["SQL Console"].click()
        XCTAssertFalse(window.scrollViews["SQL Console"].exists)
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(window.scrollViews["SQL Console"].waitForExistence(timeout: 3))
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["SQL Console"].click()
        XCTAssertTrue(window.scrollViews["SQL Console"].waitForNonExistence(timeout: 3))
        window.buttons["Row Detail"].click()
        XCTAssertTrue(window.staticTexts["detail-value-0"].waitForExistence(timeout: 3))
        XCTAssertEqual(window.staticTexts["detail-value-0"].value as? String, "First")
        window.buttons["Item List"].click()

        window.radioButtons["History"].click()
        let history = window.buttons["history-" + first]
        XCTAssertTrue(history.waitForExistence(timeout: 4))
        history.click()
        XCTAssertEqual(editor.value as? String, first)
        XCTAssertFalse(window.staticTexts["Second"].exists)
        app.menuBars.menuBarItems["Connection"].click()
        app.menuItems["Disconnect"].click()
        XCTAssertTrue(window.staticTexts["Disconnected"].waitForExistence(timeout: 3))
        XCTAssertFalse(window.buttons["Run Current"].isEnabled)
        XCTAssertEqual(editor.value as? String, first)
        window.buttons["Reconnect"].click()
        XCTAssertTrue(window.staticTexts["Disconnected"].waitForNonExistence(timeout: 4))
        window.buttons["Run Current"].click()
        XCTAssertTrue(window.staticTexts["Second"].waitForExistence(timeout: 4))
    }
}
