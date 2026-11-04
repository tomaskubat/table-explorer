import XCTest

final class SQLiteConnectionTests: XCTestCase {
    @MainActor
    func testSavingAFileProfileAndReopeningItAfterRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cities.sqlite")
        try SQLiteFixture.create(at: file)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        app.buttons["New Group"].click()
        let groupName = app.textFields["Group Name"]
        XCTAssertTrue(groupName.waitForExistence(timeout: 5))
        groupName.replaceText(with: "Development")
        app.buttons["Save"].click()
        let group = app.staticTexts["Development"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.click()

        app.buttons["New Connection"].click()
        let sqlite = app.radioButtons["SQLite"]
        XCTAssertTrue(sqlite.waitForExistence(timeout: 5))
        sqlite.click()
        app.textFields["Connection Name"].replaceText(with: "Cities")
        let path = app.textFields["Database File"]
        path.replaceText(with: file.path + ".missing")
        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".missing"))
        path.replaceText(with: file.path)
        app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["Cities"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.windows["Cities — cities.sqlite"].exists)
        app.terminate()
        app.launch()
        let saved = app.staticTexts["Cities"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.doubleClick()
        let workspace = app.windows["Cities — cities.sqlite"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertTrue(workspace.staticTexts["mesto"].waitForExistence(timeout: 5))
        workspace.staticTexts["mesto"].doubleClick()
        XCTAssertTrue(workspace.staticTexts["Brno"].waitForExistence(timeout: 5))
    }
}
