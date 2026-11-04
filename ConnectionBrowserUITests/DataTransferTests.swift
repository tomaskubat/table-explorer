import XCTest

final class DataTransferTests: XCTestCase {
    @MainActor
    func testCSVPreviewCancelImportAndJSONExport() async throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cities.sqlite")
        try SQLiteFixture.create(at: file)
        let importFile = directory.appending(path: "import.csv")
        try "id,nazev,kod_zeme,poznamka\n4,Olomouc,CZ,Ukázka\n".write(to: importFile, atomically: true, encoding: .utf8)
        let destination = directory.appending(path: "cities.json")
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        app.newProfile(driver: "SQLite")
        app.textFields["Connection Name"].replaceText(with: "Transfer")
        app.textFields["Database File"].replaceText(with: file.path)
        app.buttons["Save and Connect"].click()
        let window = app.windows["Transfer — cities.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        XCTAssertTrue(window.staticTexts["3 of 3 rows"].waitForExistence(timeout: 5))

        for confirm in [false, true] {
            window.buttons["Import CSV"].click()
            let source = app.textFields["Source File"]
            XCTAssertTrue(source.waitForExistence(timeout: 4))
            source.replaceText(with: importFile.path)
            app.buttons["Preview Import"].click()
            XCTAssertTrue(app.staticTexts["Olomouc"].firstMatch.waitForExistence(timeout: 4))
            if confirm { app.buttons["Import Rows"].click() }
            else {
                app.buttons["Cancel"].click()
                XCTAssertTrue(window.staticTexts["3 of 3 rows"].exists)
                XCTAssertFalse(window.staticTexts["Olomouc"].exists)
            }
        }
        XCTAssertTrue(window.staticTexts["4 of 4 rows"].waitForExistence(timeout: 5))
        // The first record is valid. The duplicate key in the second one
        // must roll back the entire import.
        let bad = directory.appending(path: "duplicates.csv")
        try "id,nazev,kod_zeme,poznamka\n5,Test,CZ,line\n4,Duplicate,CZ,line\n".write(to: bad, atomically: true, encoding: .utf8)
        window.buttons["Import CSV"].click()
        app.textFields["Source File"].replaceText(with: bad.path)
        app.buttons["Preview Import"].click()
        XCTAssertTrue(app.staticTexts["Duplicate"].firstMatch.waitForExistence(timeout: 4))
        app.buttons["Import Rows"].click()
        XCTAssertTrue(app.staticTexts["importError"].waitForExistence(timeout: 4))
        app.buttons["Cancel"].click()
        window.buttons["Export Data"].click()
        app.radioButtons["JSON"].click()
        app.textFields["Destination File"].replaceText(with: destination.path)
        app.buttons["Write Export"].click()
        let ready = NSPredicate { _, _ in FileManager.default.fileExists(atPath: destination.path) }
        let completed = expectation(for: ready, evaluatedWith: nil)
        await fulfillment(of: [completed], timeout: 8)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first { $0["nazev"] as? String == "Olomouc" }?["poznamka"] as? String, "Ukázka")
        XCTAssertTrue(rows.first { $0["nazev"] as? String == "Brno" }?["poznamka"] is NSNull)
        XCTAssertEqual(rows.first { $0["nazev"] as? String == "Graz" }?["poznamka"] as? String, "")
    }
}
