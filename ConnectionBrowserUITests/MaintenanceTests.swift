import XCTest

final class MaintenanceTests: XCTestCase {
    @MainActor
    func testSQLiteOnlineBackupAndRestore() throws { try roundTrip(mariaDB: false) }

    @MainActor
    func testNativeMariaDBDumpAndRestoreWithVerifiedTLS() throws {
        try XCTSkipUnless(fixtureListening(33462), "Start the TLS fixture with backup_demo.")
        try roundTrip(mariaDB: true)
    }

    @MainActor
    private func roundTrip(mariaDB: Bool) throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let target = mariaDB ? "backup_demo" : "maintenance.sqlite"
        let dbFile = directory.appending(path: target)
        if !mariaDB { try SQLiteFixture.create(at: dbFile) }
        let backup = directory.appending(path: mariaDB ? "database.sql.gz" : "database.sqlite.gz")
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        let url = mariaDB ? "mariadb://browser:local-fixture@127.0.0.1:33462/backup_demo?name=Maintenance" : dbFile.absoluteString
        app.textFields["Connection URL"].replaceText(with: url); app.buttons["Import"].click()
        app.textFields["Connection Name"].replaceText(with: "Maintenance")
        if mariaDB { app.textFields["CA Certificate Path"].replaceText(with: root.appending(path: ".build/TLSFixture/ca.crt").path) }
        app.buttons["Save and Connect"].click()
        let window = app.windows["Maintenance — " + target]
        let object = mariaDB ? "notes" : "mesto", original = mariaDB ? "Original" : "Brno"
        XCTAssertTrue(window.staticTexts[object].waitForExistence(timeout: 6))
        window.staticTexts[object].doubleClick()
        let name = window.staticTexts[original].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["File"].click(); app.menuItems["Backup Database…"].click()
        app.textFields["Maintenance File"].replaceText(with: backup.path)
        app.checkBoxes["Compress with gzip"].click()
        app.buttons["Review Backup"].click()
        XCTAssertTrue(app.buttons["Start Backup"].waitForExistence(timeout: 6), app.debugDescription)
        app.buttons["Start Backup"].click()
        let done = app.staticTexts["maintenanceResult"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), app.staticTexts["maintenanceError"].exists ? String(describing: app.staticTexts["maintenanceError"].value) : "Backup timed out")
        XCTAssertTrue(try Data(contentsOf: backup).starts(with: [0x1f, 0x8b]))
        app.buttons["Close"].click()

        name.click(); window.buttons["Edit Row"].click()
        app.textFields[mariaDB ? "edit-body" : "edit-nazev"].replaceText(with: "After backup")
        app.buttons["Stage Changes"].click(); window.buttons["Preview Changes"].click(); app.buttons["Commit Changes"].click()
        XCTAssertTrue(window.staticTexts["After backup"].firstMatch.waitForExistence(timeout: 5))

        app.menuBars.menuBarItems["File"].click(); app.menuItems["Restore Database…"].click()
        app.textFields["Maintenance File"].replaceText(with: backup.path)
        app.buttons["Review Restore"].click()
        let confirm = app.textFields["Restore Target"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Restore Database"].isEnabled)
        confirm.replaceText(with: target); app.buttons["Restore Database"].click()
        XCTAssertTrue(done.waitForExistence(timeout: 15), app.staticTexts["maintenanceError"].exists ? String(describing: app.staticTexts["maintenanceError"].value) : "Restore timed out")
        app.buttons["Close"].click()
        window.staticTexts[object].doubleClick()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(window.staticTexts["After backup"].exists)
    }
}
