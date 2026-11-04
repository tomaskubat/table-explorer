import XCTest

final class DatabaseTargetTests: XCTestCase {
    @MainActor
    func testSQLDatabaseSwitchUpdatesCatalogAndProtectsPendingRows() throws {
        try XCTSkipUnless(fixtureListening(33462), "Start the MariaDB TLS fixture.")
        continueAfterFailure = false
        let app = XCUIApplication(), dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: dir) }
        let ca = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/TLSFixture/ca.crt")
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: "mariadb://browser:local-fixture@127.0.0.1:33462/catalog?name=SchemaSwitch")
        app.buttons["Import"].click(); app.textFields["CA Certificate Path"].replaceText(with: ca.path); app.buttons["Save and Connect"].click()
        let catalog = app.windows["SchemaSwitch — catalog"]
        XCTAssertTrue(catalog.staticTexts["country"].waitForExistence(timeout: 5))
        catalog.staticTexts["country"].doubleClick()
        XCTAssertTrue(catalog.staticTexts["Czechia"].firstMatch.waitForExistence(timeout: 5))
        catalog.buttons["New Query"].click()
        catalog.textViews["SQL Editor"].replaceText(with: "USE backup_demo;")
        catalog.buttons["Run Current"].click(); app.buttons["Run Statements"].click()
        let target = app.windows["SchemaSwitch — backup_demo"]
        XCTAssertTrue(target.staticTexts["notes"].waitForExistence(timeout: 5))
        XCTAssertFalse(target.buttons["country"].exists)
        XCTAssertEqual(target.textViews["SQL Editor"].value as? String, "USE backup_demo;")
        let routine = "result_sets_" + UUID().uuidString.prefix(8).lowercased()
        let script = "DELIMITER $$\nCREATE PROCEDURE " + routine + "() BEGIN SELECT 'first set' AS v; SELECT 'second set' AS v; END$$\nDELIMITER ;\nCALL " + routine + "();\nDROP PROCEDURE " + routine + ";"
        target.textViews["SQL Editor"].replaceText(with: script)
        target.descendants(matching: .any).matching(identifier: "Run Options").firstMatch.click()
        app.menuItems["Run Script"].click(); app.buttons["Run Statements"].click()
        let resultPicker = target.popUpButtons["Statement Result"]
        XCTAssertTrue(resultPicker.waitForExistence(timeout: 5), target.staticTexts["queryError"].exists ? String(describing: target.staticTexts["queryError"].value) : target.debugDescription)
        for (index, value) in [(1, "first set"), (2, "second set")] {
            resultPicker.click(); app.menuItems["Statement 2 · Result " + String(index)].click()
            XCTAssertTrue(target.staticTexts[value].waitForExistence(timeout: 4))
        }
        target.staticTexts["notes"].doubleClick(); let original = target.staticTexts["Original"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5)); original.click()
        target.buttons["Edit Row"].click(); app.textFields["edit-body"].replaceText(with: "Staged only")
        app.buttons["Stage Changes"].click()
        target.buttons["Query 1"].click()
        let editor = target.textViews["SQL Editor"]
        // Exercise the independent server-side target check as well as the
        // normal protocol tracking tested by the first USE.
        editor.replaceText(with: "SET SESSION session_track_schema = OFF;\nUSE catalog;")
        target.descendants(matching: .any).matching(identifier: "Run Options").firstMatch.click()
        app.menuItems["Run Script"].click(); app.buttons["Run Statements"].click()
        let error = target.staticTexts["queryError"]
        XCTAssertTrue(error.waitForExistence(timeout: 6))
        XCTAssertTrue((error.value as? String)?.contains("pending changes") == true)
        editor.replaceText(with: "SET @probe = 1;\nSELECT CONCAT(DATABASE(), '/', ROW_COUNT()) AS state;")
        target.descendants(matching: .any).matching(identifier: "Run Options").firstMatch.click()
        app.menuItems["Run Script"].click(); app.buttons["Run Statements"].click()
        XCTAssertTrue(target.staticTexts["backup_demo/0"].firstMatch.waitForExistence(timeout: 6))
        target.buttons["notes"].click()
        XCTAssertTrue(target.buttons["Preview Changes"].exists)
    }
}
