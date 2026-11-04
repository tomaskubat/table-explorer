import XCTest

final class ConnectionGroupTests: XCTestCase {
    @MainActor
    func testDragWithinGroupMovesBeforeAndAfterAndPersists() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: dir) }
        try seed(dir)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        let window = app.windows["Saved Connections"]
        let a = window.staticTexts["catalog@local"], b = window.staticTexts["catalog@stage"]
        func drag(_ source: XCUIElement, _ target: XCUIElement, below: Bool) {
            let point = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .click(forDuration: 0.35, thenDragTo: point.withOffset(CGVector(dx: 0, dy: below ? 17 : -2)))
        }
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        drag(b, a, below: false)
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in b.frame.minY < a.frame.minY }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 3), .completed, "Dropping the second profile above the first must reorder the group")
        app.terminate(); app.launch()
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertLessThan(b.frame.minY, a.frame.minY)
        drag(b, a, below: true)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in a.frame.minY < b.frame.minY }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        XCTAssertGreaterThan(window.staticTexts["warehouse@local"].frame.minY, a.frame.minY)
    }

    @MainActor
    func testConnectionEditorLayoutOnDatabaseAndSSHPages() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: dir) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.newProfile(driver: "MariaDB")
        app.textFields["Connection Name"].replaceText(with: "Reporting")
        app.textFields["User"].replaceText(with: "reader")
        app.buttons["Blue status color"].click()
        app.popUpButtons["Connection Tag"].click(); app.menuItems["testing"].click()
        app.checkBoxes["Over SSH"].click()
        app.textFields["SSH Host"].replaceText(with: "reporting-bastion")

        let sheet = app.sheets.firstMatch
        func column(_ field: XCUIElement) -> CGRect { field.frame.offsetBy(dx: -sheet.frame.minX, dy: -sheet.frame.minY) }
        let user = column(app.textFields["SSH User"]), port = column(app.textFields["SSH Port"])
        for field in [app.textFields["SSH Host"], app.secureTextFields["SSH Password"], app.textFields["Private Key File"],
                      app.textFields["Known Hosts File"], app.textFields["Database Fingerprint"]] {
            XCTAssertEqual(column(field).minX, user.minX, accuracy: 2, field.identifier)
        }
        XCTAssertEqual(port.maxX, user.maxX, accuracy: 2)
        let footer = app.checkBoxes["Remember open tabs and workspace state"]
        XCTAssertEqual(column(footer).minX, column(app.checkBoxes["Use SSH key only"]).minX, accuracy: 1)
        attach(sheet, as: "SSH form")
        app.activate(); app.radioButtons["Database"].click()
        for field in [app.textFields["Connection Name"], app.textFields["Host"], app.textFields["User"], app.secureTextFields["Password"],
                      app.textFields["Database"]] {
            XCTAssertEqual(column(field).minX, user.minX, accuracy: 2, field.identifier)
        }
        XCTAssertEqual(column(app.textFields["Port"]).minX, port.minX, accuracy: 2)
        XCTAssertEqual(column(footer).minX, column(app.checkBoxes["Over SSH"]).minX, accuracy: 1)
        attach(sheet, as: "Database form")
    }

    @MainActor
    func testStatusColorAndTagSaveIndependently() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: dir) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.newProfile(driver: "MariaDB")
        app.textFields["Connection Name"].replaceText(with: "Palette example")
        app.textFields["User"].replaceText(with: "reader")
        for name in ["Neutral", "Blue", "Yellow", "Green", "Red"] { XCTAssertTrue(app.buttons[name + " status color"].isHittable, name) }
        XCTAssertTrue(app.colorWells.firstMatch.isHittable)
        let tag = app.popUpButtons["Connection Tag"]
        tag.click()
        let entries = app.menus.containing(.menuItem, identifier: "staging").firstMatch.children(matching: .menuItem)
        XCTAssertEqual(entries.allElementsBoundByIndex.map(\.title), ["local", "testing", "development", "staging", "production"])
        app.menuItems["staging"].click()
        app.buttons["Yellow status color"].click()
        app.buttons["Save"].click()
        func storedProfile() throws -> [String: Any] {
            let data = try Data(contentsOf: dir.appending(path: "connections.json"))
            let groups = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            return try XCTUnwrap((groups.first?["connections"] as? [[String: Any]])?.first)
        }
        func edit() {
            app.windows["Saved Connections"].staticTexts["Palette example"].rightClick()
            app.menuItems["Edit Connection…"].click()
        }
        XCTAssertEqual(try storedProfile()["tagColor"] as? String, "#F8F7BD")
        XCTAssertEqual(try storedProfile()["environment"] as? String, "staging")
        app.terminate(); app.launch(); edit()
        XCTAssertEqual(tag.value as? String, "staging")
        tag.click(); app.menuItems["production"].click(); app.buttons["Save"].click()
        XCTAssertEqual(try storedProfile()["tagColor"] as? String, "#F8F7BD")
        XCTAssertEqual(try storedProfile()["environment"] as? String, "production")
    }

    @MainActor
    func testCustomColorPanelUpdatesTheSavedProfile() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: dir) }
        try seed(dir)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.staticTexts["catalog@local"].rightClick(); app.menuItems["Edit Connection…"].click()
        app.colorWells.firstMatch.click()
        let colors = app.windows["Colors"]
        XCTAssertTrue(colors.waitForExistence(timeout: 4), app.windows.debugDescription)
        colors.buttons["Color Wheel"].click()
        let channel = colors.sliders.firstMatch
        XCTAssertTrue(channel.isHittable)
        channel.coordinate(withNormalizedOffset: CGVector(dx: 0.34, dy: 0.5)).click()
        colors.buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["Save"].click()
        let data = try Data(contentsOf: dir.appending(path: "connections.json"))
        let groups = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let profile = try XCTUnwrap((groups.first?["connections"] as? [[String: Any]])?.first)
        let hex = try XCTUnwrap(profile["tagColor"] as? String)
        XCTAssertNotNil(hex.range(of: "^#[0-9A-F]{6}$", options: .regularExpression), hex)
        XCTAssertEqual(profile["environment"] as? String, "local")
    }

    @MainActor
    func testCollapsingAndExpandingOneGroupPreservesItsNeighbors() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        try seed(directory)
        app.launch()

        let window = app.windows["Saved Connections"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["TableExplorer"].exists)
        let local = window.staticTexts["catalog@local"]
        let stage = window.staticTexts["catalog@stage"]
        let neighbor = window.staticTexts["warehouse@local"]
        let toggle = window.disclosureTriangles.firstMatch

        XCTAssertTrue(local.waitForExistence(timeout: 3))
        XCTAssertTrue(stage.isHittable)
        XCTAssertTrue(neighbor.isHittable)
        XCTAssertLessThan(local.frame.minY, stage.frame.minY)
        let originalNeighborY = neighbor.frame.minY

        toggle.click()
        XCTAssertTrue(local.waitForNonExistence(timeout: 3))
        XCTAssertFalse(stage.exists)
        XCTAssertTrue(neighbor.isHittable)
        XCTAssertLessThan(neighbor.frame.minY, originalNeighborY)
        attach(window, as: "Collapsed group")

        // Screenshots can hand focus back to a different open application.
        app.activate()
        window.disclosureTriangles.firstMatch.click()
        XCTAssertTrue(local.waitForExistence(timeout: 3))
        XCTAssertTrue(stage.isHittable)
        XCTAssertTrue(neighbor.isHittable)
        XCTAssertLessThan(local.frame.minY, stage.frame.minY)
        XCTAssertLessThan(stage.frame.minY, neighbor.frame.minY)
        XCTAssertEqual(neighbor.frame.minY, originalNeighborY, accuracy: 1)
        attach(window, as: "Expanded group")
    }

    @MainActor
    func testColorSortAndDragToAnotherGroupPersistAcrossLaunches() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        try seed(directory)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        let window = app.windows["Saved Connections"]
        let local = window.staticTexts["catalog@local"], stage = window.staticTexts["catalog@stage"]
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        window.staticTexts["Catalog"].rightClick(); app.menuItems["Sort Connections"].click(); app.menuItems["Status Color"].click()
        XCTAssertLessThan(stage.frame.minY, local.frame.minY)
        let warehouse = window.staticTexts["Warehouse"]
        local.click(forDuration: 0.35, thenDragTo: warehouse)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let groups = try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "connections.json"))) as? [[String: Any]],
                  let target = groups.first(where: { $0["name"] as? String == "Warehouse" }),
                  let profiles = target["connections"] as? [[String: Any]] else { return false }
            return profiles.contains { $0["name"] as? String == "catalog@local" }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        app.terminate(); app.launch()
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(local.frame.minY, warehouse.frame.minY)
        XCTAssertLessThan(stage.frame.minY, warehouse.frame.minY)
    }

    private func seed(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Tests/Fixtures/Library/connections.json")
        try FileManager.default.copyItem(at: source, to: directory.appending(path: "connections.json"))
    }

    @MainActor
    private func attach(_ window: XCUIElement, as name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
