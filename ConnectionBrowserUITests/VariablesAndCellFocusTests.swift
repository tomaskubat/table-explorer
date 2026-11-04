import XCTest

final class VariablesAndCellFocusTests: XCTestCase {
    @MainActor
    func testMariaDBVariablesReviewExpressionsAndKeepTheTemplate() throws { try checkVariables(maria: true) }

    @MainActor
    func testSQLiteVariablesAndCellFocusAfterClosingTheInspectorEditor() throws { try checkVariables(maria: false) }

    @MainActor
    private func checkVariables(maria: Bool) throws {
        if maria { try XCTSkipUnless(fixtureListening(33462), "Start the MariaDB TLS fixture.") }
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: dir) }
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let db = dir.appending(path: "variables.sqlite")
        if !maria { try SQLiteFixture.create(at: db) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: maria ? "mariadb://browser:local-fixture@127.0.0.1:33462/catalog?name=Variables" : db.absoluteString)
        app.buttons["Import"].click()
        if maria { app.textFields["CA Certificate Path"].replaceText(with: root.appending(path: ".build/TLSFixture/ca.crt").path) }
        app.buttons["Save and Connect"].click()
        let window = app.windows[maria ? "Variables — catalog" : "variables — variables.sqlite"]
        XCTAssertTrue(window.staticTexts[maria ? "country" : "mesto"].waitForExistence(timeout: 6))
        if !maria {
            window.staticTexts["mesto"].doubleClick()
            let cell = window.staticTexts["grid-1-nazev"]
            XCTAssertTrue(window.staticTexts["3 of 3 rows"].waitForExistence(timeout: 5))
            XCTAssertTrue(cell.isHittable)
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).click()
            let pencil = window.buttons["detail-edit-nazev"]
            XCTAssertTrue(pencil.waitForExistence(timeout: 4), window.debugDescription)
            pencil.click()
            XCTAssertEqual(app.textViews["Cell Value"].value as? String, "Košice")
            app.buttons["Close"].click()
            app.typeKey(.return, modifierFlags: [])
            let inline = window.textFields["grid-1-nazev"]
            XCTAssertTrue(inline.waitForExistence(timeout: 4))
            XCTAssertEqual(inline.value as? String, "Košice")
            app.typeKey(.escape, modifierFlags: [])
        }
        window.buttons["New Query"].click()
        let sql = "SELECT :city AS city_name, :amount + :amount AS total, ':untouched' AS literal /* :ignored */;"
        let editor = window.textViews["SQL Editor"]
        editor.replaceText(with: sql)
        window.descendants(matching: .any).matching(identifier: "Run Options").firstMatch.click()
        app.menuItems["Enable Query Parameters"].click()
        window.buttons["Run Current"].click()
        XCTAssertTrue(app.textFields["variable-:city"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.textFields["variable-:ignored"].exists)
        XCTAssertFalse(app.textFields["variable-:untouched"].exists)
        app.textFields["variable-:city"].replaceText(with: "'O''Brien'")
        app.textFields["variable-:amount"].replaceText(with: "21")
        app.buttons["Review SQL"].click()
        XCTAssertTrue((app.staticTexts["Expanded SQL"].value as? String)?.contains("21 + 21") == true)
        app.buttons["Run Statements"].click()
        XCTAssertTrue(window.staticTexts["O'Brien"].firstMatch.waitForExistence(timeout: 6))
        XCTAssertTrue(window.staticTexts["42"].firstMatch.exists)
        XCTAssertEqual(editor.value as? String, sql)
        window.buttons["Run Current"].click()
        XCTAssertEqual(app.textFields["variable-:city"].value as? String, "'O''Brien'")
        app.buttons["Cancel"].click()
        let files = try fm.contentsOfDirectory(at: dir.appending(path: "Queries"), includingPropertiesForKeys: nil)
        let history = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertTrue(history.contains(":city")); XCTAssertFalse(history.contains("O''Brien"))
    }
}
