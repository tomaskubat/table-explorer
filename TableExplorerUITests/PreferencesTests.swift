import XCTest

final class PreferencesTests: XCTestCase {
    @MainActor
    func testStartupPreferenceReopensOnlyWorkspacesLeftOpenAtQuit() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = directory.appending(path: "startup.sqlite")
        try SQLiteFixture.create(at: db)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "General").firstMatch.click()
        let reopen = app.checkBoxes["Reopen closed workspaces at startup"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 4))
        XCTAssertEqual((reopen.value as? NSNumber)?.intValue ?? Int(reopen.value as? String ?? ""), 0)
        reopen.setChecked(true)
        let generalImage = XCTAttachment(screenshot: app.windows.containing(.checkBox, identifier: "Reopen closed workspaces at startup").firstMatch.screenshot())
        generalImage.name = "General settings"; generalImage.lifetime = .keepAlways; add(generalImage)
        app.activate()
        app.typeKey("w", modifierFlags: .command)
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["startup — startup.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        XCTAssertTrue(window.staticTexts["Brno"].waitForExistence(timeout: 5))
        let chooser = app.savedConnections()
        chooser.staticTexts["startup"].rightClick(); app.menuItems["Duplicate"].click()
        app.textFields["Connection Name"].replaceText(with: "Second startup")
        app.buttons["Save and Connect"].click()
        let blank = app.windows["Second startup — startup.sqlite"]
        XCTAssertTrue(blank.buttons["New Query"].waitForExistence(timeout: 5))
        blank.buttons["New Query"].click()
        let host = app.windows.containing(.button, identifier: "Saved Connections").firstMatch
        XCTAssertTrue(host.textViews["SQL Editor"].waitForExistence(timeout: 5))
        func relaunch() {
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
            app.launch()
        }
        relaunch()
        XCTAssertTrue(host.textViews["SQL Editor"].waitForExistence(timeout: 8), "Restore the connection that was active at quit.")
        XCTAssertTrue(host.buttons["Connection startup"].exists)
        XCTAssertTrue(chooser.waitForNonExistence(timeout: 5))
        host.buttons["Connection startup"].click()
        XCTAssertTrue(host.staticTexts["Brno"].waitForExistence(timeout: 8))
        host.buttons["Connection startup"].rightClick(); app.menuItems["Close Connection"].click()
        XCTAssertTrue(host.buttons["Connection startup"].waitForNonExistence(timeout: 4))
        relaunch()
        XCTAssertTrue(host.textViews["SQL Editor"].waitForExistence(timeout: 8))
        XCTAssertFalse(host.buttons["Connection startup"].exists, "Do not resurrect a manually closed connection.")
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "General").firstMatch.click()
        reopen.setChecked(false); app.typeKey("w", modifierFlags: .command)
        relaunch()
        XCTAssertTrue(app.windows["Saved Connections"].waitForExistence(timeout: 5))
        XCTAssertFalse(host.waitForExistence(timeout: 2), "Disabling startup restoration leaves the connection picker open.")

    }

    @MainActor
    func testRecordingShortcutChangesTheCommandAndSurvivesRelaunch() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = directory.appending(path: "keymap.sqlite"); try SQLiteFixture.create(at: db)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "Shortcuts").firstMatch.click()
        let recorder = app.buttons["Shortcut New Query"]
        let keymapImage = XCTAttachment(screenshot: app.windows.containing(.button, identifier: "Shortcut New Query").firstMatch.screenshot())
        keymapImage.name = "Keyboard settings"; keymapImage.lifetime = .keepAlways; add(keymapImage)
        app.activate(); recorder.click(); app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Already assigned to Open Anything."].waitForExistence(timeout: 3))
        app.typeKey("j", modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: .command)
        app.terminate(); app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["keymap — keymap.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertFalse(window.textViews["SQL Editor"].exists)
        app.typeKey("j", modifierFlags: [.command, .shift])
        XCTAssertTrue(window.textViews["SQL Editor"].waitForExistence(timeout: 4))
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "Shortcuts").firstMatch.click()
        app.buttons["Clear New Query"].click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("j", modifierFlags: [.command, .shift])
        XCTAssertFalse(window.buttons["Query 2"].exists)
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "Shortcuts").firstMatch.click()
        app.buttons["Restore Defaults"].click()
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(window.buttons["Query 2"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testEditorPreferencesAffectTypingButPreserveQuotedSQLAndPaste() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = directory.appending(path: "editing.sqlite"); try SQLiteFixture.create(at: db)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        XCTAssertTrue(app.windows["Saved Connections"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "Editor").firstMatch.click()
        app.checkBoxes["Automatically uppercase SQL keywords"].setChecked(true)
        app.checkBoxes["Automatically insert closing brackets and quotes"].setChecked(true)
        app.typeKey("w", modifierFlags: .command)
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["editing — editing.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.buttons["New Query"].click()
        let sql = window.textViews["SQL Editor"]
        sql.click()
        sql.typeText("select '")
        XCTAssertEqual(sql.value as? String, "SELECT ''")
        sql.typeText("from here'")
        XCTAssertEqual(sql.value as? String, "SELECT 'from here'")
        sql.replaceText(with: "select (1) -- where")
        XCTAssertEqual(sql.value as? String, "select (1) -- where")
    }

    @MainActor
    func testMariaDBEstimatesAreLabeledAndTheTimeoutStopsLongSQL() throws {
        try XCTSkipUnless(fixtureListening(33461), "Start the local MariaDB fixture with scale.sql.")
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "General").firstMatch.click()
        app.checkBoxes["Estimate large MariaDB table counts"].setChecked(true)
        let timeout = app.textFields["Query timeout"]; timeout.replaceText(with: "1"); timeout.typeKey(.return, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: "mariadb://browser:local-fixture@127.0.0.1:33461/catalog?tls=disabled&name=Preferences")
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["Preferences — catalog"]
        let table = window.staticTexts["million_rows"]; XCTAssertTrue(table.waitForExistence(timeout: 5)); table.doubleClick()
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "≈")).firstMatch.waitForExistence(timeout: 5))
        window.buttons["Next Page"].click()
        XCTAssertTrue(window.staticTexts["row-0000301"].waitForExistence(timeout: 5))
        window.buttons["New Query"].click()
        let editor = window.textViews["SQL Editor"]; editor.replaceText(with: "SELECT SLEEP(12)")
        window.buttons["Run Current"].click()
        XCTAssertTrue(window.staticTexts["queryError"].waitForExistence(timeout: 5))
        XCTAssertTrue((window.staticTexts["queryError"].value as? String)?.contains("time limit") == true)
    }

    @MainActor
    func testNewTablesAndSQLHonorSavedPreferences() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = directory.appending(path: "prefs.sqlite")
        try SQLiteFixture.create(at: db)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        XCTAssertTrue(app.windows["Saved Connections"].waitForExistence(timeout: 5))
        app.typeKey(",", modifierFlags: .command)
        let general = app.descendants(matching: .any).matching(identifier: "General").firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        general.click()
        let pageSize = app.popUpButtons["Default Page Size"]
        XCTAssertTrue(pageSize.waitForExistence(timeout: 5))
        pageSize.click(); app.menuItems["25"].click()
        app.descendants(matching: .any).matching(identifier: "Security").firstMatch.click()
        app.popUpButtons["SQL Safety"].click(); app.menuItems["Review every statement"].click()
        app.typeKey("w", modifierFlags: .command)
        app.terminate(); app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString)
        app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["prefs — prefs.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        XCTAssertTrue(window.descendants(matching: .any).matching(identifier: "Page Size: 25").firstMatch.waitForExistence(timeout: 5))
        window.buttons["New Query"].click()
        app.activate()
        let editor = window.textViews["SQL Editor"]
        editor.replaceText(with: "SELECT 'reviewed' AS result;")
        XCTAssertEqual(editor.value as? String, "SELECT 'reviewed' AS result;")
        window.buttons["Run Current"].click()
        XCTAssertTrue(app.buttons["Run Statements"].waitForExistence(timeout: 5))
        app.buttons["Run Statements"].click()
        XCTAssertTrue(window.staticTexts["reviewed"].waitForExistence(timeout: 5))
    }
}
