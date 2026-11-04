import AppKit
import XCTest

final class WorkspaceLayoutTests: XCTestCase {
    @MainActor
    func testSQLiteGridSitsBetweenTitleAndFooterWithInspectorBesideIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: dir) }
        let file = dir.appending(path: "katalog.sqlite")
        try SQLiteFixture.create(at: file)
        let fixture = try Data(contentsOf: root.appending(path: "Tests/Fixtures/Library/connections.json"))
        var groups = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [[String: Any]])
        var profiles = try XCTUnwrap(groups[0]["connections"] as? [[String: Any]])
        var sqlite = profiles[0]
        sqlite["id"] = UUID().uuidString; sqlite["name"] = "Katalog"; sqlite["driver"] = "SQLite"; sqlite["filePath"] = file.path
        sqlite.removeValue(forKey: "tagColor")
        profiles.append(sqlite); groups[0]["connections"] = profiles
        var archive = sqlite
        archive["id"] = UUID().uuidString; archive["name"] = "Archive"; archive["filePath"] = dir.appending(path: "archive.sqlite").path
        try fm.copyItem(at: file, to: dir.appending(path: "archive.sqlite"))
        groups[1]["connections"] = [archive]
        try JSONSerialization.data(withJSONObject: groups).write(to: dir.appending(path: "connections.json"))
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()

        let chooser = app.windows["Saved Connections"]
        let saved = chooser.staticTexts["Katalog"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(saved.frame.minX, chooser.buttons["Export Connections"].frame.maxX)
        // A01: 250 pt welcome panel, then an 11 pt inset for the create action.
        XCTAssertEqual(chooser.buttons["New Connection"].frame.minX - chooser.frame.minX, 261, accuracy: 4)
        attach(chooser, "Saved connections")
        app.newProfile(driver: "MariaDB")
        let profile = app.sheets.firstMatch
        XCTAssertTrue(profile.textFields["Host"].isHittable)
        XCTAssertTrue(profile.buttons["Test Connection"].exists)
        attach(profile, "MariaDB connection profile")
        profile.buttons["Cancel"].click()
        chooser.staticTexts["Archive"].doubleClick()
        XCTAssertTrue(app.windows["Archive — archive.sqlite"].waitForExistence(timeout: 5))
        app.typeKey("n", modifierFlags: .command)
        saved.doubleClick()
        let window = app.windows["Katalog — katalog.sqlite"]
        let object = window.staticTexts["mesto"]
        XCTAssertTrue(object.waitForExistence(timeout: 5))
        fitReferenceViewport(window)
        object.doubleClick()
        let city = window.staticTexts["grid-0-nazev"]
        XCTAssertTrue(city.waitForExistence(timeout: 5))
        let search = window.textFields["Search for field"], data = window.radioButtons["Data"]
        XCTAssertLessThan(city.frame.minY - window.frame.minY, 100)
        XCTAssertLessThan(object.frame.maxX, city.frame.minX)
        XCTAssertGreaterThan(search.frame.minX, city.frame.maxX)
        XCTAssertGreaterThan(data.frame.minY, city.frame.maxY)
        XCTAssertLessThan(data.frame.maxY, window.scrollViews["SQL Console"].frame.minY)
        let next = window.staticTexts["grid-1-nazev"]
        // I04: the native table advances by 28 pt between adjacent records.
        XCTAssertEqual(next.frame.midY - city.frame.midY, 28, accuracy: 1)
        // Make this workspace key before sending modified mouse events; the
        // archive window and the connection chooser are also open.
        app.activate()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 18 / window.frame.height)).click()
        city.click()
        XCUIElement.perform(withKeyModifiers: .shift) { next.click() }
        attach(window, "SQLite two selected rows")
        XCTAssertTrue(window.staticTexts["2 rows selected"].waitForExistence(timeout: 4))
        window.buttons["Export Data"].click()
        let export = app.sheets.firstMatch
        XCTAssertTrue(export.textFields["Destination File"].waitForExistence(timeout: 4))
        attach(export, "CSV export options")
        export.buttons["Cancel"].click()
        window.buttons["New Query"].click()
        let editor = window.textViews["SQL Editor"]
        editor.replaceText(with: "SELECT 'CZ' AS kod, 'Česko' AS zeme UNION ALL SELECT 'SK', 'Slovensko';")
        window.buttons["Run Current"].click()
        XCTAssertTrue(window.staticTexts["Slovensko"].waitForExistence(timeout: 5))
        attach(window, "Query editor and result")
    }

    /// I04 was captured at 1692 × 965 points. Compare at that size on displays
    /// that can fit it; on a smaller Mac the same behavioral checks still run.
    @MainActor private func fitReferenceViewport(_ window: XCUIElement) {
        let size = CGSize(width: 1692, height: 965)
        guard let primary = NSScreen.screens.first else { return }
        let regions = NSScreen.screens.map { screen in
            let f = screen.visibleFrame
            return CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        }
        let frame = window.frame
        guard let display = regions.first(where: { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
              display.width >= size.width + 4, display.height >= size.height + 4 else { return }
        let dx = display.midX - size.width / 2 - frame.minX
        let dy = display.midY - size.height / 2 - frame.minY
        let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 18 / frame.height))
        title.click(forDuration: 0.15, thenDragTo: title.withOffset(CGVector(dx: dx, dy: dy)))
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -4, dy: -4))
        corner.click(forDuration: 0.15, thenDragTo: corner.withOffset(CGVector(dx: size.width - window.frame.width,
                                                                                dy: size.height - window.frame.height)))
    }

    @MainActor private func attach(_ window: XCUIElement, _ name: String) {
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.lifetime = .keepAlways; shot.name = name; add(shot)
    }
}
