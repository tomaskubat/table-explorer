import XCTest
import SQLite3

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

        app.newProfile(driver: "SQLite")
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
        workspace.radioButtons["Structure"].click()
        workspace.popUpButtons["Structure Section"].click()
        app.menuItems["Indexes"].click()
        XCTAssertTrue(workspace.staticTexts["ix_mesto_zeme"].firstMatch.waitForExistence(timeout: 5))
        workspace.radioButtons["Data"].click()
        app.menuBars.menuBarItems["Database"].click()
        XCTAssertFalse(app.menuItems["Server Accounts…"].exists)
        app.menuItems["New Table…"].click()
        app.textFields["Object Name"].replaceText(with: "local_draft")
        app.buttons["Preview DDL"].click()
        XCTAssertTrue(app.staticTexts["ddlPreview"].waitForExistence(timeout: 3))
        XCTAssertTrue((app.staticTexts["ddlPreview"].value as? String)?.contains("CREATE TABLE") == true)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "SQLite schema preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Discard Draft"].click()
        XCTAssertFalse(workspace.staticTexts["local_draft"].exists)
        app.menuBars.menuBarItems["Database"].click()
        app.menuItems["New View…"].click()
        app.textFields["Object Name"].replaceText(with: "city_ids")
        app.textViews["View Definition"].replaceText(with: "SELECT id FROM mesto")
        app.buttons["Preview DDL"].click()
        app.buttons["Apply DDL"].click()
        XCTAssertTrue(workspace.staticTexts["city_ids"].waitForExistence(timeout: 5))

        let brno = workspace.staticTexts["Brno"]
        XCTAssertTrue(brno.waitForExistence(timeout: 5))
        brno.firstMatch.click()
        workspace.buttons["Edit Row"].click()
        let name = app.textFields["edit-nazev"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.replaceText(with: "Brno City")
        app.buttons["Stage Changes"].click()
        workspace.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 5))
        app.buttons["Keep Editing"].click()
        workspace.buttons["Preview Changes"].click()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "UPDATE")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Close Preview"].click()
        workspace.buttons["Discard Changes"].click()
        XCTAssertTrue(brno.firstMatch.waitForExistence(timeout: 3))

        brno.firstMatch.click()
        workspace.buttons["Edit Row"].click()
        name.replaceText(with: "Brno City")
        app.buttons["Stage Changes"].click()
        workspace.buttons["Preview Changes"].click()
        app.buttons["Commit Changes"].click()
        let changed = workspace.staticTexts["Brno City"]
        XCTAssertTrue(changed.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try readName(file), "Brno City")

        changed.firstMatch.click()
        workspace.buttons["Edit Row"].click()
        name.replaceText(with: "Local draft")
        app.buttons["Stage Changes"].click()
        var external: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &external, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(external, "UPDATE mesto SET nazev='External edit' WHERE id=1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(external)
        workspace.buttons["Preview Changes"].click()
        app.buttons["Commit Changes"].click()
        XCTAssertTrue(app.staticTexts["commitError"].waitForExistence(timeout: 5))
        XCTAssertEqual(try readName(file), "External edit")
    }

    private func readName(_ file: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT nazev FROM mesto WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return String(cString: sqlite3_column_text(statement, 0))
    }
}
