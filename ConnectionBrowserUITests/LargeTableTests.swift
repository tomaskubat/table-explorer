import XCTest

final class LargeTableTests: XCTestCase {
    @MainActor
    func testMillionRowsStayPagedAndALongRunningQueryCanBeStoppedFromItsOwnTab() throws {
        try XCTSkipUnless(fixtureListening(33461), "Start the MariaDB fixture with scale.sql.")
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        app.buttons["New Connection"].click()
        app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: "mariadb://browser:local-fixture@127.0.0.1:33461/catalog?tls=disabled&name=Scale")
        app.buttons["Import"].click()
        app.buttons["Save and Connect"].click()
        let window = app.windows["Scale — catalog"]
        XCTAssertTrue(window.waitForExistence(timeout: 6))
        let table = window.staticTexts["million_rows"]
        XCTAssertTrue(table.waitForExistence(timeout: 4))
        table.doubleClick()
        let status = window.staticTexts.matching(NSPredicate(format: "value MATCHES %@", "300 of 1[^0-9]?000[^0-9]?000 rows")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 8), window.debugDescription)
        XCTAssertTrue(window.staticTexts["row-0000001"].exists)
        window.buttons["Next Page"].click()
        XCTAssertTrue(window.staticTexts["row-0000301"].waitForExistence(timeout: 6))
        XCTAssertFalse(window.staticTexts["row-0000001"].exists)

        window.buttons["New Query"].click()
        window.textViews["SQL Editor"].replaceText(with: "SELECT SLEEP(30) AS slow_result;")
        window.buttons["Run Current"].click()
        window.buttons["million_rows"].click()
        XCTAssertTrue(window.staticTexts["row-0000301"].exists)
        window.buttons["Query 1"].click()
        let stop = window.buttons["Stop Query"]
        XCTAssertTrue(stop.isEnabled)
        stop.click()
        // Depending on server version, SLEEP() returns 1 or an interruption error.
        XCTAssertTrue(stop.waitForNonExistence(timeout: 8))
        window.buttons["million_rows"].click()
        XCTAssertTrue(window.staticTexts["row-0000301"].exists)
        XCTAssertFalse(window.staticTexts["slow_result"].exists)
    }
}
