import XCTest

final class GridInteractionTests: XCTestCase {
    @MainActor
    func testContextActionsUseTheClickedCellAndTheSelectedRowsIndependently() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let database = directory.appending(path: "grid.sqlite")
        try SQLiteFixture.create(at: database)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()

        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertFalse(app.menuItems["Add Row"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["New Connection"].click()
        app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: database.absoluteString)
        app.buttons["Import"].click()
        app.buttons["Save and Connect"].click()
        let window = app.windows["grid — grid.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 6))
        window.staticTexts["mesto"].doubleClick()
        let brno = window.staticTexts["grid-0-nazev"]
        let kosice = window.staticTexts["grid-1-nazev"]
        XCTAssertTrue(brno.waitForExistence(timeout: 5))
        brno.click()
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertTrue(app.menuItems["Add Row"].isEnabled)
        XCTAssertFalse(app.menuItems["Toggle Line Comment"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCUIElement.perform(withKeyModifiers: .command) { kosice.click() }
        XCTAssertTrue(window.staticTexts["2 rows selected"].exists)
        kosice.rightClick()
        app.menuItems["Duplicate"].click()
        window.buttons["Preview Changes"].click()
        let preview = app.staticTexts["changePreviewSQL"].value as? String ?? ""
        XCTAssertEqual(preview.components(separatedBy: "INSERT INTO").count - 1, 2)
        XCTAssertTrue(preview.contains("Brno") && preview.contains("Košice"))
        XCTAssertFalse(preview.contains("\u{60}id\u{60}"))
        app.buttons["Close Preview"].click()
        window.descendants(matching: .any).matching(identifier: "Row Actions").firstMatch.click()
        app.menuItems["Undo Last Change"].click()
        XCTAssertFalse(window.buttons["Preview Changes"].exists)

        window.staticTexts["grid-2-nazev"].rightClick()
        app.menuItems["Quick Filter"].click()
        XCTAssertTrue(app.menuItems["nazev = 'Graz'"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(window.staticTexts["2 rows selected"].exists)

        window.staticTexts["grid-0-poznamka"].rightClick()
        app.menuItems["Quick Filter"].click()
        XCTAssertFalse(app.menuItems["poznamka = ''"].exists)
        app.menuItems["poznamka IS NULL"].click()
        XCTAssertTrue(window.staticTexts["1 of 1 rows"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.staticTexts["grid-0-nazev"].value as? String, "Brno")
        window.buttons["Unset"].click()
        XCTAssertTrue(window.staticTexts["grid-2-poznamka"].waitForExistence(timeout: 4))
        window.staticTexts["grid-2-poznamka"].rightClick()
        app.menuItems["Quick Filter"].click()
        app.menuItems["poznamka = ''"].click()
        XCTAssertTrue(window.staticTexts["1 of 1 rows"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.staticTexts["grid-0-nazev"].value as? String, "Graz")

        let graz = window.staticTexts["grid-0-nazev"]
        graz.doubleClick()
        app.typeText("Graz edited")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(window.buttons["Preview Changes"].waitForExistence(timeout: 3))
        window.buttons["Preview Changes"].click()
        let cellSQL = app.staticTexts["changePreviewSQL"].value as? String ?? ""
        XCTAssertTrue(cellSQL.contains("Graz edited") && cellSQL.contains("= 3"))
        app.buttons["Close Preview"].click()
        window.buttons["Discard Changes"].click()
        window.buttons["New Query"].click()
        let editor = window.textViews["SQL Editor"]
        editor.replaceText(with: "SELECT 42;")
        app.menuBars.menuBarItems["Edit"].click()
        XCTAssertFalse(app.menuItems["Add Row"].isEnabled)
        XCTAssertTrue(app.menuItems["Toggle Line Comment"].isEnabled)
        app.menuItems["Toggle Line Comment"].click()
        XCTAssertEqual(editor.value as? String, "-- SELECT 42;")
    }
}
