import XCTest

final class PreferencesTests: XCTestCase {
    @MainActor
    func testNewTablesAndSQLHonorSavedPreferences() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = directory.appending(path: "prefs.sqlite")
        try SQLiteFixture.create(at: db)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.typeKey(",", modifierFlags: .command)
        let pageSize = app.popUpButtons["Default Page Size"]
        XCTAssertTrue(pageSize.waitForExistence(timeout: 5))
        pageSize.click(); app.menuItems["25"].click()
        app.descendants(matching: .any).matching(identifier: "Security").firstMatch.click()
        app.popUpButtons["SQL Safety"].click(); app.menuItems["Review every statement"].click()
        app.typeKey("w", modifierFlags: .command)
        app.terminate(); app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["prefs — prefs.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "Page Size: 25").firstMatch.waitForExistence(timeout: 5))
        window.buttons["New Query"].click()
        window.textViews["SQL Editor"].replaceText(with: "SELECT 'reviewed' AS result;")
        window.buttons["Run Current"].click()
        XCTAssertTrue(app.buttons["Run Statements"].waitForExistence(timeout: 5))
        app.buttons["Run Statements"].click()
        XCTAssertTrue(window.staticTexts["reviewed"].waitForExistence(timeout: 5))
    }
}
