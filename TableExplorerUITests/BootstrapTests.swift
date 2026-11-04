import XCTest
import SQLite3

final class BootstrapTests: XCTestCase {
    @MainActor
    func testBootstrapRunsOnlyAfterReviewAndUsesTheSelectedProfile() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: dir) }
        let db = dir.appending(path: "startup.sqlite")
        try SQLiteFixture.create(at: db)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.newProfile(driver: "SQLite")
        app.textFields["Connection Name"].replaceText(with: "Reviewed Startup")
        app.textFields["Database File"].replaceText(with: db.path)
        app.textFields["Environment"].replaceText(with: "production")
        app.buttons["Bootstrap SQL…"].click()
        app.textViews["Bootstrap Editor"].replaceText(with: "UPDATE mesto SET nazev='Startup' WHERE id=1;")
        app.buttons["Done"].click()
        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["Connection succeeded"].waitForExistence(timeout: 5))
        XCTAssertEqual(try name(in: db), "Brno")
        app.buttons["Save and Connect"].click()
        XCTAssertTrue(app.buttons["Skip Bootstrap"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["PRODUCTION"].firstMatch.exists)
        app.buttons["Skip Bootstrap"].click()
        XCTAssertEqual(try name(in: db), "Brno")
        let window = app.windows["Reviewed Startup — startup.sqlite"]
        app.menuBars.menuBarItems["Connection"].click(); app.menuItems["Disconnect"].click()
        window.buttons["Reconnect"].click()
        XCTAssertTrue(app.buttons["Run Bootstrap"].waitForExistence(timeout: 5))
        app.buttons["Run Bootstrap"].click()
        XCTAssertTrue(window.textViews["SQL Editor"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "value ENDSWITH %@", " · 1 affected row")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try name(in: db), "Startup")
    }

    private func name(in file: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT nazev FROM mesto WHERE id=1", -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { throw CocoaError(.fileReadUnknown) }
        return String(cString: value)
    }
}
