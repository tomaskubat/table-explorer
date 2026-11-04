import XCTest

final class ConnectionGroupTests: XCTestCase {
    @MainActor
    func testCollapsingAndExpandingOneGroupPreservesItsNeighbors() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
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
    private func attach(_ window: XCUIElement, as name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
