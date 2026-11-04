import Darwin
import XCTest

final class MariaDBTransportTests: XCTestCase {
    private var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    @MainActor
    func testVerifiedTLSRejectsAnUnknownCAAndNegotiatesACipherWithTheFixtureCA() throws {
        let ca = root.appending(path: ".build/TLSFixture/ca.crt")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ca.path) && fixtureListening(33462), "Run bash Tests/Fixtures/MariaDB/start-tls.sh")
        let (app, directory) = try startApp()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        try enterProfile(app, name: "Secure Catalog")
        app.textFields["Port"].replaceText(with: "33462")
        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 8))
        app.textFields["CA Certificate Path"].replaceText(with: ca.path)
        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["Connection succeeded"].waitForExistence(timeout: 8))
        app.buttons["Save and Connect"].click()
        let window = app.windows["Secure Catalog — catalog"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.buttons["New Query"].click()
        window.textViews["SQL Editor"].replaceText(with: "SHOW SESSION STATUS LIKE 'Ssl_cipher';")
        window.buttons["Run Current"].click()
        let cipher = window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'TLS_' OR value CONTAINS 'GCM'")).firstMatch
        XCTAssertTrue(cipher.waitForExistence(timeout: 5))
    }

    @MainActor
    func testUnixSocketConnectsThroughTheSelectedPath() throws {
        try XCTSkipUnless(fixtureListening(33461), "Start the local MariaDB fixture.")
        let socketPath = root.appending(path: ".build/SocketFixture/db.sock")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: socketPath.path), "Start python3 Tests/Fixtures/MariaDB/socket-relay.py")
        let (app, directory) = try startApp()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        try enterProfile(app, name: "Socket Catalog")
        app.checkBoxes["Require verified TLS"].click()
        app.checkBoxes["Use Unix socket"].click()
        app.textFields["Socket Path"].replaceText(with: socketPath.path + ".missing")
        app.buttons["Test Connection"].click()
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 5))
        app.textFields["Socket Path"].replaceText(with: socketPath.path)
        app.buttons["Save and Connect"].click()
        let window = app.windows["Socket Catalog — catalog"]
        XCTAssertTrue(window.staticTexts["country"].waitForExistence(timeout: 8), app.staticTexts["connectionError"].exists ? String(describing: app.staticTexts["connectionError"].value) : "Missing workspace")
    }

    @MainActor
    private func startApp() throws -> (XCUIApplication, URL) {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appending(path: "cb" + UUID().uuidString.prefix(7))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let app = XCUIApplication()
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        return (app, directory)
    }
    @MainActor
    private func enterProfile(_ app: XCUIApplication, name: String) throws {
        app.newProfile(driver: "MariaDB")
        XCTAssertTrue(app.textFields["Connection Name"].waitForExistence(timeout: 4))
        app.textFields["Connection Name"].replaceText(with: name)
        app.textFields["User"].replaceText(with: "browser")
        app.secureTextFields["Password"].replaceText(with: "local-fixture")
        app.textFields["Database"].replaceText(with: "catalog")
    }
}

func fixtureListening(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
    }
}
