import XCTest

final class SQLFileTests: XCTestCase {
    @MainActor
    func testStandaloneAndConnectedEditorsSaveTheChosenFileWithoutExecutingIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: directory) }
        let file = directory.appending(path: "review.sql"), db = directory.appending(path: "files.sqlite")
        try SQLiteFixture.create(at: db)
        try "SELECT 'original';".write(to: file, atomically: true, encoding: .utf8)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()

        func openFile() {
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["Open SQL File…"].click()
            app.typeKey("g", modifierFlags: [.command, .shift])
            app.typeText(file.path)
            app.typeKey(.return, modifierFlags: [])
            app.buttons["Open"].firstMatch.click()
        }
        openFile()
        let document = app.textViews["SQL Editor"].firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(document.value as? String, "SELECT 'original';")
        XCTAssertFalse(app.buttons["Open in Workspace"].isEnabled)
        let saved = "SELECT 'from document';"
        document.replaceText(with: saved)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(waitForSave(file, expected: saved))
        app.typeKey("w", modifierFlags: .command)

        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["files — files.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Window"].click(); app.menuItems["Show Workspaces"].click()
        let overview = app.windows["Workspaces"]
        XCTAssertTrue(overview.buttons["files / files.sqlite"].waitForExistence(timeout: 5))
        overview.buttons["files / files.sqlite"].click()

        openFile()
        let editor = window.textViews["SQL Editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, saved)
        XCTAssertFalse(window.staticTexts["from document"].exists)
        let edited = "SELECT 'from workspace';"
        editor.replaceText(with: edited)
        XCTAssertEqual(editor.value as? String, edited)
        XCTAssertTrue(window.buttons["review.sql"].exists, window.debugDescription)
        app.menuBars.menuBarItems["File"].click()
        let save = app.menuItems["Save Query"]
        XCTAssertTrue(save.exists && save.isEnabled, app.menuBars.menuBarItems["File"].debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        editor.click(); editor.typeKey("s", modifierFlags: .command)
        if !waitForSave(file, expected: edited) {
            XCTFail("Workspace shortcut did not save to the opened file. " + app.windows.allElementsBoundByIndex.map { $0.title }.joined(separator: ", "))
        }
        window.buttons["Run Current"].click()
        XCTAssertTrue(window.staticTexts["from workspace"].waitForExistence(timeout: 5))
        editor.replaceText(with: "SELECT 'discard';")
        window.buttons["Close Tab"].click()
        app.buttons["Discard and Close"].click()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 4))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), edited)
    }

    @MainActor
    private func waitForSave(_ file: URL, expected: String) -> Bool {
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: file, encoding: .utf8)) == expected
        }, object: nil)
        return XCTWaiter.wait(for: [saved], timeout: 5) == .completed
    }
}
