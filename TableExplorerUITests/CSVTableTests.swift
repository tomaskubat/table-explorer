import XCTest

final class CSVTableTests: XCTestCase {
    @MainActor
    func testSQLiteCreatesTableAndRollsBackBadTypedRows() throws { try importNewTable(maria: false) }

    @MainActor
    func testMariaDBPublishesCompletedTableAndCleansUpFailedImports() throws {
        try XCTSkipUnless(fixtureListening(33462), "Start the MariaDB TLS fixture.")
        try importNewTable(maria: true)
    }

    @MainActor
    private func importNewTable(maria: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: dir) }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let db = dir.appending(path: "imports.sqlite")
        if !maria { try SQLiteFixture.create(at: db) }
        let item = "csv_" + UUID().uuidString.prefix(8).lowercased()
        let invalid = dir.appending(path: "invalid.csv"), valid = dir.appending(path: "valid.csv")
        try "code,name\n1,Okay\nwrong,Bad\n".write(to: invalid, atomically: true, encoding: .utf8)
        try "code,name\n1,Olomouc\n2,Žatec\n".write(to: valid, atomically: true, encoding: .utf8)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        let url = maria ? "mariadb://browser:local-fixture@127.0.0.1:33462/backup_demo?name=CSV" : db.absoluteString
        app.textFields["Connection URL"].replaceText(with: url); app.buttons["Import"].click()
        if maria { app.textFields["CA Certificate Path"].replaceText(with: root.appending(path: ".build/TLSFixture/ca.crt").path) }
        app.buttons["Save and Connect"].click()
        let window = app.windows[maria ? "CSV — backup_demo" : "imports — imports.sqlite"]
        XCTAssertTrue(window.staticTexts[maria ? "notes" : "mesto"].waitForExistence(timeout: 6))
        for (source, shouldFail) in [(invalid, true), (valid, false)] {
            app.menuBars.menuBarItems["File"].click(); app.menuItems["Import CSV…"].click()
            app.popUpButtons["Import Destination"].click(); app.menuItems["Create New Table"].click()
            app.textFields["New Table Name"].replaceText(with: item)
            app.textFields["Source File"].replaceText(with: source.path); app.buttons["Preview Import"].click()
            let type = app.popUpButtons["type-0"]
            XCTAssertTrue(type.waitForExistence(timeout: 5))
            type.click(); app.menuItems["Integer"].click()
            XCTAssertTrue((app.staticTexts["importDDL"].value as? String)?.contains(maria ? "BIGINT" : "INTEGER") == true)
            app.buttons["Create and Import"].click()
            if shouldFail {
                let error = app.staticTexts["importError"]
                XCTAssertTrue(error.waitForExistence(timeout: 5))
                XCTAssertTrue((error.value as? String)?.contains("Line 3") == true)
                app.buttons["Cancel"].click()
            } else {
                XCTAssertTrue(window.staticTexts[item].firstMatch.waitForExistence(timeout: 5))
            }
        }
        let target = window.staticTexts[item].firstMatch
        XCTAssertTrue(app.buttons["Create and Import"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["2 of 2 rows"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Žatec"].firstMatch.exists)
        target.rightClick(); app.menuItems["Delete Object…"].click()
        app.buttons["Preview Operation"].click()
        app.textFields["Confirm Object Name"].replaceText(with: item); app.buttons["Apply Operation"].click()
        XCTAssertTrue(target.waitForNonExistence(timeout: 5))
        window.buttons["New Query"].click()
        let probe = maria ? "SELECT COUNT(*) AS leftovers FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND LEFT(TABLE_NAME,5)='_csv_'" : "SELECT COUNT(*) AS leftovers FROM sqlite_schema WHERE name='" + item + "'"
        window.textViews["SQL Editor"].replaceText(with: probe); window.buttons["Run Current"].click()
        XCTAssertTrue(window.staticTexts["0"].firstMatch.waitForExistence(timeout: 5))
    }
}
