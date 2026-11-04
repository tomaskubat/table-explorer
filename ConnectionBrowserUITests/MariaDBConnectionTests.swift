import XCTest
import Darwin

final class MariaDBConnectionTests: XCTestCase {
    @MainActor
    func testCorrectingAnInvalidPortOpensTheRealMariaDBCatalog() throws {
        // The shared scheme can also run on developer machines without Docker.
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(33461).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let available = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        try XCTSkipUnless(available, "Start the MariaDB fixture in Tests/Fixtures/MariaDB.")
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()

        app.buttons["New Connection"].click()
        XCTAssertTrue(app.textFields["Connection Name"].waitForExistence(timeout: 5), app.debugDescription)
        app.textFields["Connection Name"].replaceText(with: "Fixture Catalog")
        app.textFields["Port"].replaceText(with: "1")
        app.textFields["User"].replaceText(with: "browser")
        app.secureTextFields["Password"].replaceText(with: "local-fixture")
        app.textFields["Database"].replaceText(with: "catalog")
        app.checkBoxes["Require verified TLS"].click()

        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Connection Name"].value as? String, "Fixture Catalog")
        app.textFields["Port"].replaceText(with: "33461")
        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["Connection succeeded"].waitForExistence(timeout: 10), app.staticTexts["connectionError"].exists ? String(describing: app.staticTexts["connectionError"].value) : "No test result")
        app.buttons["Save and Connect"].click()
        let workspace = app.windows["Fixture Catalog — catalog"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        XCTAssertTrue(workspace.staticTexts["country"].waitForExistence(timeout: 5))
        XCTAssertTrue(workspace.staticTexts["country_names"].exists)
        workspace.staticTexts["country"].doubleClick()
        XCTAssertTrue(workspace.staticTexts["Czechia"].waitForExistence(timeout: 5))
    }
}
