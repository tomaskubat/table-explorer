import XCTest

final class ConnectionGroupTests: XCTestCase {
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

        toggle.click()
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
        window.staticTexts["Catalog"].rightClick(); app.menuItems["Sort Connections"].click(); app.menuItems["Color Tag"].click()
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
