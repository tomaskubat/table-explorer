import XCTest
import SQLite3

final class ObjectToolsTests: XCTestCase {
    @MainActor
    func testClonePreservesKeysAndIndexesAndDestructiveActionsOnlyAffectTheClone() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: directory) }
        let db = directory.appending(path: "objects.sqlite")
        try SQLiteFixture.create(at: db)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["objects — objects.sqlite"]
        let original = window.staticTexts["mesto"]
        XCTAssertTrue(original.waitForExistence(timeout: 6))
        original.rightClick(); app.menuItems["Pin to Top"].click()
        XCTAssertTrue(window.staticTexts["Pinned"].waitForExistence(timeout: 4))
        original.rightClick(); app.menuItems["Item Overview"].click()
        XCTAssertTrue(app.staticTexts["Object Overview"].waitForExistence(timeout: 3))
        app.buttons["Close Overview"].click()
        original.rightClick(); app.menuItems["Clone…"].click()
        app.textFields["New Object Name"].replaceText(with: "cities_copy")
        app.buttons["Preview Operation"].click()
        let preview = app.staticTexts["objectPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue((preview.value as? String)?.contains("CREATE INDEX") == true)
        app.buttons["Apply Operation"].click()
        let clone = window.staticTexts["cities_copy"].firstMatch
        XCTAssertTrue(clone.waitForExistence(timeout: 5))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM cities_copy", db), 3)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM pragma_table_info('cities_copy') WHERE pk=1", db), 1)
        clone.rightClick(); app.menuItems["Empty Table…"].click()
        app.buttons["Preview Operation"].click()
        XCTAssertFalse(app.buttons["Apply Operation"].isEnabled)
        app.textFields["Confirm Object Name"].replaceText(with: "cities_copy")
        app.buttons["Apply Operation"].click()
        XCTAssertTrue(app.buttons["Apply Operation"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM cities_copy", db), 0)
        clone.rightClick(); app.menuItems["Delete Object…"].click()
        app.buttons["Preview Operation"].click()
        app.textFields["Confirm Object Name"].replaceText(with: "cities_copy")
        app.buttons["Apply Operation"].click()
        XCTAssertTrue(clone.waitForNonExistence(timeout: 5))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM mesto", db), 3)
    }
    @MainActor
    func testMariaDBRoutineDefinitionIsReviewedAndOpenedWithoutRunningIt() throws {
        try XCTSkipUnless(fixtureListening(33462), "Start the TLS fixture with backup_demo.")
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: directory) }
        let name = "test_routine_" + UUID().uuidString.prefix(8).lowercased()
        let ca = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/TLSFixture/ca.crt")
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: "mariadb://browser:local-fixture@127.0.0.1:33462/backup_demo?name=Routines")
        app.buttons["Import"].click()
        app.textFields["CA Certificate Path"].replaceText(with: ca.path)
        app.buttons["Save and Connect"].click()
        let window = app.windows["Routines — backup_demo"]
        XCTAssertTrue(window.staticTexts["notes"].waitForExistence(timeout: 6))
        app.menuBars.menuBarItems["Database"].click(); app.menuItems["New Procedure…"].click()
        app.textFields["Object Name"].replaceText(with: name)
        let body = "BEGIN\n  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'procedure invoked';\nEND"
        app.textViews["Routine Body"].replaceText(with: body)
        app.buttons["Preview DDL"].click()
        let preview = app.staticTexts["ddlPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertTrue((preview.value as? String)?.contains("CREATE PROCEDURE") == true)
        app.buttons["Apply DDL"].click()
        let routine = window.staticTexts[name].firstMatch
        XCTAssertTrue(routine.waitForExistence(timeout: 5))
        routine.doubleClick()
        let definition = window.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "CREATE", "procedure invoked")).firstMatch
        XCTAssertTrue(definition.waitForExistence(timeout: 4))
        XCTAssertFalse(window.staticTexts["queryError"].exists)
        routine.rightClick(); app.menuItems["Delete Object…"].click()
        app.buttons["Preview Operation"].click()
        app.textFields["Confirm Object Name"].replaceText(with: name)
        app.buttons["Apply Operation"].click()
        XCTAssertTrue(routine.waitForNonExistence(timeout: 5))
    }

    private func scalar(_ sql: String, _ file: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
        return Int(sqlite3_column_int64(query, 0))
    }
}
