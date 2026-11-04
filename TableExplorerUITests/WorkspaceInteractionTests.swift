import AppKit
import XCTest

final class WorkspaceInteractionTests: XCTestCase {
    /// A populated workspace with a private database; no user profile is opened.
    @MainActor private func inCatalog(_ run: (XCUIElement) throws -> Void) throws {
        try inCatalog { _, window in try run(window) }
    }

    @MainActor private func inCatalog(_ run: (XCUIApplication, XCUIElement) throws -> Void) throws {
        let app = XCUIApplication(), fm = FileManager.default
        let p = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: p, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: p) }
        let db = p.appending(path: "qa.sqlite")
        try SQLiteFixture.create(at: db)
        let profile: [String: Any] = ["id": UUID().uuidString, "name": "QA", "driver": "SQLite",
            "filePath": db.path, "host": "", "port": "", "user": "", "database": "", "environment": "local",
            "socketPath": "", "usesSocket": false, "verifyTLS": false, "caPath": "", "rememberPassword": false]
        try JSONSerialization.data(withJSONObject: [["id": UUID().uuidString, "name": "Fixtures", "connections": [profile]]])
            .write(to: p.appending(path: "connections.json"))
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = p.path
        app.launch()
        let saved = app.windows["Saved Connections"].staticTexts["QA"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.doubleClick()
        let window = app.windows["QA — qa.sqlite"]
        let city = window.staticTexts["mesto"]
        XCTAssertTrue(city.waitForExistence(timeout: 5)); city.click()
        XCTAssertTrue(window.staticTexts["grid-0-nazev"].waitForExistence(timeout: 4))
        try run(app, window)
    }

    @MainActor func testTabContextMenuUsesClickedTabAndProtectsDirtyTabs() throws {
        continueAfterFailure = false
        try inCatalog { app, window in
            func open(_ name: String) {
                window.staticTexts[name].doubleClick()
                XCTAssertTrue(window.buttons["workspace-tab-" + name].waitForExistence(timeout: 4))
            }
            func close(_ action: String, at tab: String) {
                window.buttons["workspace-tab-" + tab].rightClick()
                app.menuItems[action].click()
            }
            open("zeme"); open("v_mesta")
            window.buttons["workspace-tab-mesto"].rightClick()
            XCTAssertFalse(app.menuItems["Close Tabs to the Left"].isEnabled)
            app.typeKey(.escape, modifierFlags: [])
            close("Close Tabs to the Right", at: "zeme")
            XCTAssertFalse(window.buttons["workspace-tab-v_mesta"].exists)
            XCTAssertTrue(window.staticTexts["grid-0-kod"].waitForExistence(timeout: 3))
            open("v_mesta")
            close("Close Tabs to the Left", at: "zeme")
            XCTAssertFalse(window.buttons["workspace-tab-mesto"].exists)
            open("mesto")
            close("Close Other Tabs", at: "zeme")
            XCTAssertTrue(window.staticTexts["grid-0-kod"].waitForExistence(timeout: 3))
            window.buttons["New Query"].click()
            window.textViews["SQL Editor"].replaceText(with: "SELECT 42;")
            window.buttons["workspace-tab-zeme"].rightClick()
            app.menuItems["Rename Tab…"].click()
            app.textFields["Tab Name"].replaceText(with: "Countries")
            app.buttons["Rename"].click()
            close("Close All Tabs", at: "Countries")
            app.buttons["Keep Editing"].click()
            XCTAssertEqual(window.textViews["SQL Editor"].value as? String, "SELECT 42;")
            XCTAssertTrue(window.buttons["workspace-tab-Countries"].exists)
            close("Close All Tabs", at: "Countries")
            app.buttons["Discard Changes and Close"].click()
            XCTAssertTrue(window.staticTexts["No Open Tabs"].waitForExistence(timeout: 4))
        }
    }

    @MainActor func testProfileRestoresOpenTabsAndCanForgetThem() throws {
        continueAfterFailure = false
        try inCatalog { app, window in
            let profile = app.windows["Saved Connections"].staticTexts["QA"]
            func closeWindow() {
                window.buttons[XCUIIdentifierCloseWindow].click()
                XCTAssertTrue(window.waitForNonExistence(timeout: 5))
            }
            window.staticTexts["zeme"].click()
            XCTAssertTrue(window.staticTexts["grid-0-kod"].waitForExistence(timeout: 5))
            window.radioButtons["Structure"].click()
            window.buttons["Row Detail"].click()
            closeWindow()
            app.terminate(); app.launch()
            profile.doubleClick()
            XCTAssertTrue(window.buttons["workspace-tab-mesto"].waitForExistence(timeout: 5))
            XCTAssertTrue(window.buttons["workspace-tab-zeme"].exists)
            XCTAssertTrue(window.popUpButtons["Structure Section"].exists)
            XCTAssertFalse(window.textFields["Search for field"].exists)
            window.buttons["workspace-tab-mesto"].click()
            XCTAssertTrue(window.staticTexts["grid-0-nazev"].waitForExistence(timeout: 5))
            closeWindow()
            profile.rightClick(); app.menuItems["Edit Connection…"].click()
            let remember = app.checkBoxes["Remember open tabs and workspace state"]
            XCTAssertTrue(remember.waitForExistence(timeout: 5))
            remember.setChecked(false)
            app.buttons["Save"].click()
            profile.doubleClick()
            XCTAssertTrue(window.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
            XCTAssertTrue(window.textFields["Search for field"].exists)
            window.staticTexts["zeme"].click()
            XCTAssertTrue(window.staticTexts["grid-0-kod"].waitForExistence(timeout: 4))
            closeWindow(); profile.doubleClick()
            XCTAssertTrue(window.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
        }
    }

    @MainActor func testQuittingAppRemembersStillOpenWorkspace() throws {
        continueAfterFailure = false
        try inCatalog { app, window in
            window.staticTexts["zeme"].click()
            XCTAssertTrue(window.staticTexts["grid-0-kod"].waitForExistence(timeout: 5))
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 8))
            app.launch()
            app.windows["Saved Connections"].staticTexts["QA"].doubleClick()
            XCTAssertTrue(window.staticTexts["grid-0-kod"].waitForExistence(timeout: 5))
            XCTAssertTrue(window.buttons["workspace-tab-mesto"].exists)
        }
    }

    @MainActor func testDoubleClickOnConnectionStatusFillsScreenAndRestoresWindow() throws {
        continueAfterFailure = false
        try inCatalog { window in
            let primary = try XCTUnwrap(NSScreen.screens.first)
            let original = window.frame
            let visible = try XCTUnwrap(NSScreen.screens.map { screen in
                let f = screen.visibleFrame
                return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
            }.first { $0.contains(CGPoint(x: original.midX, y: original.midY)) })
            let status = window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "SQLite : QA :")).firstMatch
            XCTAssertTrue(status.exists)
            func doubleClickStatus() { status.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick() }
            // Start unzoomed even if a previous run left the workspace maximized.
            if abs(window.frame.width - visible.width) < 3 {
                let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -3, dy: -3))
                corner.click(forDuration: 0.15, thenDragTo: corner.withOffset(CGVector(dx: -120, dy: -70)))
            }
            let start = window.frame
            doubleClickStatus()
            XCTAssertEqual(window.frame.width, visible.width, accuracy: 3)
            XCTAssertEqual(window.frame.height, visible.height, accuracy: 3)
            doubleClickStatus()
            XCTAssertEqual(window.frame.minX, start.minX, accuracy: 3)
            XCTAssertEqual(window.frame.minY, start.minY, accuracy: 3)
            XCTAssertEqual(window.frame.width, start.width, accuracy: 3)
            XCTAssertEqual(window.frame.height, start.height, accuracy: 3)
        }
    }

    @MainActor func testSwitchingTablesKeepsTheirSelectionAndDraftsSeparate() throws {
        continueAfterFailure = false
        try inCatalog { w in
            let app = XCUIApplication()
            let name = w.staticTexts["grid-0-nazev"]
            name.doubleClick()
            app.typeText("Draft city"); app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(w.buttons["Preview Changes"].waitForExistence(timeout: 3))
            w.staticTexts["zeme"].click()
            XCTAssertTrue(w.staticTexts["grid-0-kod"].waitForExistence(timeout: 4))
            XCTAssertEqual(name.value as? String, "Rakousko")
            XCTAssertFalse(w.buttons["Preview Changes"].exists)
            w.staticTexts["grid-1-kod"].click()
            w.buttons["mesto"].click()
            XCTAssertEqual(name.value as? String, "✎ Draft city")
            XCTAssertTrue(w.buttons["Preview Changes"].exists)
            w.buttons["zeme"].click()
            XCTAssertTrue(w.staticTexts["1 of 3 rows selected"].exists)
            XCTAssertEqual(w.staticTexts["detail-value-0"].value as? String, "CZ")
        }
    }

    @MainActor func testDraggingConsoleResizesBothWaysAndSurvivesToggling() throws {
        continueAfterFailure = false
        try inCatalog { w in
            let console = w.scrollViews["SQL Console"]
            @MainActor func drag(_ dy: CGFloat) {
                let edge = console.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0))
                    .withOffset(CGVector(dx: 0, dy: -2))
                edge.click(forDuration: 0.18, thenDragTo: edge.withOffset(CGVector(dx: 0, dy: dy)))
            }
            let initial = console.frame.height
            let firstRow = w.staticTexts["grid-0-nazev"], footer = w.radioButtons["Data"]
            let gridInitially = footer.frame.minY - firstRow.frame.minY
            drag(-90)
            let expanded = console.frame.height
            XCTAssertGreaterThan(expanded, initial + 65)
            XCTAssertLessThan(footer.frame.minY - firstRow.frame.minY, gridInitially - 65)
            drag(45)
            let adjusted = console.frame.height
            XCTAssertLessThan(adjusted, expanded - 25)
            w.buttons["SQL Console"].click()
            XCTAssertTrue(console.waitForNonExistence(timeout: 3))
            w.buttons["SQL Console"].click()
            XCTAssertTrue(console.waitForExistence(timeout: 3))
            XCTAssertEqual(console.frame.height, adjusted, accuracy: 4)
        }
    }

    @MainActor func testCommandWClosesOnlyTheActiveTabThenLeavesTheSessionOpen() throws {
        continueAfterFailure = false
        try inCatalog { w in
            w.staticTexts["zeme"].click()
            XCTAssertTrue(w.staticTexts["grid-0-kod"].waitForExistence(timeout: 4))
            w.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(w.staticTexts["grid-0-nazev"].waitForExistence(timeout: 3))
            XCTAssertEqual(w.staticTexts["grid-0-nazev"].value as? String, "Brno")
            w.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(w.staticTexts["No Open Tabs"].waitForExistence(timeout: 3))
            w.buttons["New Query"].click()
            w.textViews["SQL Editor"].replaceText(with: "SELECT 42;")
            w.typeKey("w", modifierFlags: .command)
            let app = XCUIApplication()
            XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 3))
            app.buttons["Keep Editing"].click()
            XCTAssertEqual(w.textViews["SQL Editor"].value as? String, "SELECT 42;")
        }
    }

    @MainActor func testCloseOnInactiveTabPreservesCurrentTableAndDirtyQuery() throws {
        continueAfterFailure = false
        try inCatalog { w in
            w.staticTexts["zeme"].click()
            XCTAssertTrue(w.staticTexts["grid-0-kod"].waitForExistence(timeout: 4))
            w.buttons["New Query"].click()
            w.textViews["SQL Editor"].replaceText(with: "SELECT 42;")
            w.buttons["zeme"].click()
            let closeCity = w.buttons["Close mesto"]
            XCTAssertTrue(closeCity.isHittable)
            closeCity.click()
            XCTAssertFalse(w.buttons["mesto"].exists)
            XCTAssertTrue(w.staticTexts["grid-0-kod"].exists)
            w.buttons["Close Query 1"].click()
            let app = XCUIApplication()
            XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 4))
            app.buttons["Keep Editing"].click()
            XCTAssertTrue(w.staticTexts["grid-0-kod"].exists)
            w.buttons["Query 1"].click()
            XCTAssertEqual(w.textViews["SQL Editor"].value as? String, "SELECT 42;")
        }
    }
}
