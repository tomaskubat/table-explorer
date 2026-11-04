import XCTest
import Darwin

final class MariaDBConnectionTests: XCTestCase {
    @MainActor
    func testCorrectingAnInvalidPortOpensTheRealMariaDBCatalog() throws {
        // The shared scheme can also run on developer machines without Docker.
        try XCTSkipUnless(fixtureListening(33461), "Start the MariaDB fixture in Tests/Fixtures/MariaDB.")
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()

        app.newProfile(driver: "MariaDB")
        XCTAssertTrue(app.textFields["Connection Name"].waitForExistence(timeout: 5), app.debugDescription)
        app.textFields["Connection Name"].replaceText(with: "Fixture Catalog")
        app.textFields["Port"].replaceText(with: "1")
        app.textFields["User"].replaceText(with: "browser")
        app.secureTextFields["Password"].replaceText(with: "local-fixture")
        app.textFields["Database"].replaceText(with: "catalog")
        app.checkBoxes["Require verified TLS"].click()

        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Connection Name"].value as? String, "Fixture Catalog")
        app.textFields["Port"].replaceText(with: "33461")
        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["Connection succeeded"].waitForExistence(timeout: 10), app.staticTexts["connectionError"].exists ? String(describing: app.staticTexts["connectionError"].value) : "No test result")
        app.buttons["Save and Connect"].click()
        let workspace = app.windows["Fixture Catalog — catalog"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        XCTAssertTrue(workspace.staticTexts["country"].waitForExistence(timeout: 5))
        XCTAssertTrue(workspace.staticTexts["country_names"].exists)
        XCTAssertTrue(workspace.staticTexts["list_countries"].waitForExistence(timeout: 5))
        workspace.staticTexts["list_countries"].doubleClick()
        XCTAssertTrue(workspace.staticTexts["routineUnavailable"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Database"].click()
        app.menuItems["Server Accounts…"].click()
        XCTAssertTrue(app.staticTexts["serverToolError"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.staticTexts["serverToolError"].value as? String)?.contains("1142") == true)
        app.buttons["Close Server Tool"].click()
        workspace.staticTexts["country"].doubleClick()
        XCTAssertTrue(workspace.staticTexts["Czechia"].waitForExistence(timeout: 5))
        workspace.buttons["Filters"].click()
        workspace.textFields["Filter Value"].replaceText(with: "CZ")
        workspace.buttons["Apply Filters"].click()
        XCTAssertTrue(workspace.staticTexts["Austria"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(workspace.staticTexts["Czechia"].exists)
        XCTAssertTrue(workspace.staticTexts["1 of 1 rows"].exists)
        workspace.staticTexts["Czechia"].firstMatch.click()
        let screenshot = XCTAttachment(screenshot: workspace.screenshot())
        screenshot.name = "MariaDB filtered table and row detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        workspace.buttons["Unset"].click()
        XCTAssertTrue(workspace.staticTexts["Austria"].waitForExistence(timeout: 5))

        let marker = "Verified " + UUID().uuidString.prefix(8)
        workspace.staticTexts["Czechia"].firstMatch.click()
        workspace.buttons["Edit Row"].click()
        let note = app.textFields["edit-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 4))
        let previous = note.value as? String ?? ""
        let mode = try XCTUnwrap(app.popUpButtons["mode-note"].value as? String)
        XCTAssertTrue(["NULL", "Value"].contains(mode))
        let wasNull = mode == "NULL"
        note.replaceText(with: marker)
        app.buttons["Stage Changes"].click()
        workspace.buttons["Preview Changes"].click()
        app.buttons["Commit Changes"].click()
        XCTAssertTrue(workspace.staticTexts[marker].firstMatch.waitForExistence(timeout: 5))
        // Read again from the server before restoring the fixture.
        workspace.buttons["Unset"].click()
        XCTAssertTrue(workspace.staticTexts[marker].firstMatch.waitForExistence(timeout: 5))
        workspace.staticTexts["Czechia"].firstMatch.click()
        workspace.buttons["Edit Row"].click()
        if wasNull {
            app.popUpButtons["mode-note"].click()
            app.menuItems["NULL"].click()
        } else { note.replaceText(with: previous) }
        app.buttons["Stage Changes"].click()
        workspace.buttons["Preview Changes"].click()
        app.buttons["Commit Changes"].click()
        XCTAssertTrue(workspace.staticTexts[marker].firstMatch.waitForNonExistence(timeout: 5))

        workspace.staticTexts["Czechia"].firstMatch.click()
        workspace.buttons["Edit Row"].click()
        note.replaceText(with: "Unsaved draft")
        app.buttons["Stage Changes"].click()
        workspace.buttons["New Query"].click()
        workspace.textViews["SQL Editor"].replaceText(with: "KILL CONNECTION CONNECTION_ID();")
        workspace.buttons["Run Current"].click()
        app.buttons["Run Statements"].click()
        XCTAssertTrue(workspace.staticTexts["Disconnected"].waitForExistence(timeout: 5))
        workspace.buttons["country"].click()
        XCTAssertTrue(workspace.staticTexts["Unsaved draft"].firstMatch.exists)
        workspace.buttons["Preview Changes"].click()
        XCTAssertFalse(app.buttons["Commit Changes"].isEnabled)
        app.buttons["Close Preview"].click()
        workspace.buttons["Reconnect"].click()
        XCTAssertTrue(workspace.staticTexts["Disconnected"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(workspace.staticTexts["Unsaved draft"].firstMatch.exists)
        workspace.buttons["Discard Changes"].click()
    }
}
