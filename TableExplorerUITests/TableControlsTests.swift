import XCTest
import SQLite3

final class TableControlsTests: XCTestCase {
    @MainActor
    func testPreviewWrapsLongChangesAndConsoleRespectsManualScrolling() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "preview.sqlite")
        try SQLiteFixture.create(at: file)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: file.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["preview — preview.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].click()
        let first = window.staticTexts["grid-0-nazev"], second = window.staticTexts["grid-1-nazev"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let longValue = "A semicolon; and 'quotes' " + String(repeating: "long preview value ", count: 20)
        first.doubleClick(); app.typeText(longValue); app.typeKey(.return, modifierFlags: [])
        second.doubleClick(); app.typeText("Second row"); app.typeKey(.return, modifierFlags: [])
        window.buttons["Review Staged Changes"].click()
        let preview = app.staticTexts["changePreviewSQL"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let sql = preview.value as? String ?? ""
        XCTAssertTrue(sql.contains("\nSET\n  ") && sql.contains(";\n\nUPDATE") && sql.contains("\nWHERE\n  "))
        XCTAssertTrue(sql.contains(longValue.replacingOccurrences(of: "'", with: "''")))
        let viewport = app.sheets.scrollViews.firstMatch
        XCTAssertLessThanOrEqual(preview.frame.maxX, viewport.frame.maxX + 1)
        XCTAssertGreaterThan(preview.frame.height, 200)
        app.buttons["Close Preview"].click(); window.buttons["Discard Staged Changes"].click()

        let console = window.scrollViews["SQL Console"], scroller = console.scrollBars.firstMatch
        func waitForPosition(atEnd: Bool) {
            let predicate = NSPredicate { _, _ in
                let value = (scroller.value as? NSNumber)?.doubleValue ?? (scroller.value as? String).flatMap(Double.init) ?? -1
                return atEnd ? value >= 0.99 : (0...0.1).contains(value)
            }
            let position = XCTNSPredicateExpectation(predicate: predicate, object: scroller)
            XCTAssertEqual(XCTWaiter.wait(for: [position], timeout: 5), .completed)
        }
        for _ in 0..<10 { app.typeKey("r", modifierFlags: .command) }
        waitForPosition(atEnd: true)
        console.scroll(byDeltaX: 0, deltaY: 1000)
        waitForPosition(atEnd: false)
        app.typeKey("r", modifierFlags: .command)
        waitForPosition(atEnd: false)
        console.scroll(byDeltaX: 0, deltaY: -2000)
        waitForPosition(atEnd: true)
        app.typeKey("r", modifierFlags: .command)
        waitForPosition(atEnd: true)
    }

    @MainActor
    func testCopyStructureNamesAndOpenFiltersFromOtherPanes() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "keyboard.sqlite")
        try SQLiteFixture.create(at: file)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: file.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["keyboard — keyboard.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].click()
        XCTAssertTrue(window.staticTexts["grid-0-nazev"].waitForExistence(timeout: 5))
        window.radioButtons["Structure"].click()
        let name = window.tables["Query Results"].descendants(matching: .any).matching(identifier: "kod_zeme").firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.doubleClick(); app.typeKey("c", modifierFlags: .command)
        let search = window.textFields["Search for item"]
        search.click(); app.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(search.value as? String, "kod_zeme")
        search.replaceText(with: "")

        app.typeKey("f", modifierFlags: .command)
        let value = window.textFields["Filter Value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertEqual(window.radioButtons["Data"].value as? Int, 1)
        XCTAssertEqual(window.popUpButtons["Filter Operator"].value as? String, "Raw SQL")
        app.typeText("id = 1")
        XCTAssertEqual(value.value as? String, "id = 1")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(window.staticTexts["1 of 1 rows"].waitForExistence(timeout: 5))
        search.click(); app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(value.exists)
        XCTAssertEqual(value.value as? String, "id = 1")
        window.buttons["Filters"].click()
        window.textFields["Search for field"].click(); app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        window.buttons["Filters"].click()
        window.scrollViews["SQL Console"].click(); app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(value.waitForExistence(timeout: 5))
    }

    @MainActor
    func testRemovingFiltersHidesThePanelOnlyAfterTheLastCondition() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "remove-filter.sqlite")
        try SQLiteFixture.create(at: file)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: file.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["remove-filter — remove-filter.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].click()
        XCTAssertTrue(window.staticTexts["grid-0-nazev"].waitForExistence(timeout: 5))
        window.buttons["Filters"].click()
        let values = window.textFields.matching(identifier: "Filter Value")
        let remove = window.buttons.matching(identifier: "Remove condition")
        let apply = window.buttons.matching(identifier: "Apply condition")
        values.element(boundBy: 0).replaceText(with: "1"); apply.element(boundBy: 0).click()
        XCTAssertTrue(window.staticTexts["1 of 1 rows"].waitForExistence(timeout: 5))
        remove.element(boundBy: 0).click()
        XCTAssertTrue(window.staticTexts["3 of 3 rows"].waitForExistence(timeout: 5))
        XCTAssertEqual(values.count, 0)
        XCTAssertFalse(window.buttons["Add Condition"].exists)
        XCTAssertFalse(window.buttons["Unset"].exists)
        XCTAssertFalse(window.buttons["Apply Filters"].exists)

        window.buttons["Filters"].click()
        values.element(boundBy: 0).replaceText(with: "1"); apply.element(boundBy: 0).click()
        window.buttons["Add Condition"].click(); values.element(boundBy: 1).replaceText(with: "2")
        remove.element(boundBy: 0).click()
        XCTAssertTrue(window.staticTexts["3 of 3 rows"].waitForExistence(timeout: 5))
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.element(boundBy: 0).value as? String, "2")
        apply.element(boundBy: 0).click()
        XCTAssertTrue(window.staticTexts["1 of 1 rows"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.staticTexts["grid-0-nazev"].value as? String, "Košice")

        window.buttons["Add Condition"].click(); values.element(boundBy: 1).replaceText(with: "3")
        remove.element(boundBy: 1).click()
        XCTAssertEqual(values.count, 1)
        XCTAssertTrue(window.staticTexts["1 of 1 rows"].exists)
        window.buttons["Add Condition"].click(); values.element(boundBy: 1).replaceText(with: "3")
        window.buttons["Unset"].click()
        XCTAssertTrue(window.staticTexts["3 of 3 rows"].waitForExistence(timeout: 5))
        XCTAssertEqual(values.count, 0)
        XCTAssertFalse(window.buttons["Add Condition"].exists)
        XCTAssertFalse(window.buttons["Unset"].exists)
    }

    @MainActor
    func testRefreshShortcutAndButtonReloadExternalChanges() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "refresh.sqlite")
        try SQLiteFixture.create(at: file)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: file.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["refresh — refresh.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].click()
        let cell = window.staticTexts["grid-0-nazev"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &writer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(writer) }
        func waitForName(_ name: String) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", name), object: cell)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        }
        XCTAssertEqual(sqlite3_exec(writer, "UPDATE mesto SET nazev='Shortcut update' WHERE id=1", nil, nil, nil), SQLITE_OK)
        window.textFields["Search for field"].click()
        app.typeKey("r", modifierFlags: .command)
        waitForName("Shortcut update")
        XCTAssertEqual(sqlite3_exec(writer, "UPDATE mesto SET nazev='Button update' WHERE id=1", nil, nil, nil), SQLITE_OK)
        window.buttons["Refresh Data"].click()
        waitForName("Button update")
        cell.doubleClick(); app.typeText("Local draft"); app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(window.buttons["Preview Changes"].waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["Refresh Data"].isEnabled)
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue((cell.value as? String)?.contains("Local draft") == true)
    }

    @MainActor
    func testApplyOneFilterAndCommitOnTabClose() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { app.terminate(); try? FileManager.default.removeItem(at: dir) }
        let db = dir.appending(path: "filters.sqlite")
        try SQLiteFixture.create(at: db)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString); app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["filters — filters.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        let cell = window.staticTexts["grid-0-nazev"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5)); cell.click()
        app.typeKey("f", modifierFlags: .command)
        let fields = window.textFields.matching(identifier: "Filter Value")
        fields.element(boundBy: 0).replaceText(with: "id = 1")
        window.buttons["Add Condition"].click(); fields.element(boundBy: 1).replaceText(with: "2")
        fields.element(boundBy: 0).click(); app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "1 of 1 row")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(cell.value as? String, "Brno")
        fields.element(boundBy: 1).click(); app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(window.staticTexts["0 of 0 rows"].waitForExistence(timeout: 5))
        XCTAssertEqual(fields.count, 2)
        window.buttons["Unset"].click(); XCTAssertTrue(window.staticTexts["3 of 3 rows"].waitForExistence(timeout: 5))
        cell.click(); window.buttons["Edit Row"].click()
        app.textFields["edit-nazev"].replaceText(with: "Saved before closing")
        app.buttons["Stage Changes"].click()
        XCTAssertEqual(window.buttons["Review Staged Changes"].value as? String, "Pending changes")
        XCTAssertEqual(window.buttons["Discard Staged Changes"].value as? String, "Pending changes")
        window.buttons["Close Tab"].click()
        app.buttons["Review and Commit…"].click()
        XCTAssertTrue(app.staticTexts["changePreviewSQL"].waitForExistence(timeout: 5))
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(db.path, &writer, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        app.buttons["Commit Changes"].click()
        let locked = app.staticTexts.containing(NSPredicate(format: "value CONTAINS[c] 'database is locked'")).firstMatch
        XCTAssertTrue(locked.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["changePreviewSQL"].exists)
        XCTAssertEqual(sqlite3_exec(writer, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        app.buttons["Commit Changes"].click()
        XCTAssertTrue(window.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.buttons["Review Staged Changes"].value as? String, "No pending changes")
        XCTAssertFalse(window.buttons["Discard Staged Changes"].isEnabled)
        let committed = window.scrollViews["SQL Console"].staticTexts.containing(NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "UPDATE", "Saved before closing")).firstMatch
        XCTAssertTrue(committed.waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        XCTAssertTrue(window.staticTexts["Saved before closing"].firstMatch.waitForExistence(timeout: 5))
    }
}
