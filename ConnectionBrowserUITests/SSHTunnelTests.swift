import XCTest

final class SSHTunnelTests: XCTestCase {
    @MainActor
    func testRejectsUnknownHostKeyAndOpensMariaDBWithAnSSHIdentity() throws {
        try exercise(identity: true, tls: false)
    }

    @MainActor
    func testSSHPasswordAndDatabasePasswordAuthenticateSeparately() throws {
        try exercise(identity: false, tls: false)
    }

    @MainActor
    func testPinnedDatabaseCertificateOverSSH() throws {
        try exercise(identity: true, tls: true)
    }

    @MainActor
    private func exercise(identity: Bool, tls: Bool) throws {
        let port: UInt16 = tls ? 33464 : 33463
        try XCTSkipUnless(fixtureListening(port), "Run sh Tests/Fixtures/SSH/start-ssh.sh")
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/SSHFixture")
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        app.newProfile(driver: "MariaDB")
        app.textFields["Connection Name"].replaceText(with: "Tunneled")
        app.textFields["Host"].replaceText(with: "database")
        app.textFields["User"].replaceText(with: "browser")
        app.secureTextFields["Password"].replaceText(with: "local-fixture")
        app.textFields["Database"].replaceText(with: "catalog")
        if !tls { app.checkBoxes["Require verified TLS"].click() }
        app.checkBoxes["Over SSH"].click()
        XCTAssertTrue(app.textFields["SSH Host"].waitForExistence(timeout: 5))
        app.textFields["SSH Host"].replaceText(with: "127.0.0.1")
        app.textFields["SSH Port"].replaceText(with: String(port))
        app.textFields["SSH User"].replaceText(with: "tunnel")
        if identity {
            app.textFields["Private Key File"].replaceText(with: fixture.appending(path: "client").path)
        }
        if identity && !tls {
            app.textFields["Known Hosts File"].replaceText(with: fixture.appending(path: "untrusted").path)
            app.buttons["Test Connection"].click()
            let failure = app.staticTexts["connectionError"]
            XCTAssertTrue(failure.waitForExistence(timeout: 10))
            XCTAssertTrue((failure.value as? String)?.localizedCaseInsensitiveContains("host key verification failed") == true)
        } else if !identity {
            app.secureTextFields["SSH Password"].replaceText(with: "incorrect-fixture-password")
        }
        app.textFields["Known Hosts File"].replaceText(with: fixture.appending(path: "known_hosts").path)
        if !identity {
            app.buttons["Test Connection"].click()
            let failure = app.staticTexts["connectionError"]
            XCTAssertTrue(failure.waitForExistence(timeout: 12))
            XCTAssertTrue((failure.value as? String)?.localizedCaseInsensitiveContains("permission denied") == true)
            app.secureTextFields["SSH Password"].replaceText(with: "tunnel-fixture")
        }
        if tls {
            let pin = app.textFields["Database Fingerprint"]
            pin.replaceText(with: String(repeating: "0", count: 64))
            app.buttons["Test Connection"].click()
            XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 10))
            let fingerprint = try String(contentsOf: fixture.deletingLastPathComponent().appending(path: "TLSFixture/fingerprint"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            pin.replaceText(with: fingerprint)
        }
        app.buttons["Test Connection"].click()
        let success = app.staticTexts["Connection succeeded"]
        XCTAssertTrue(success.waitForExistence(timeout: 15), app.staticTexts["connectionError"].exists ? String(describing: app.staticTexts["connectionError"].value) : "Timed out")
        app.buttons["Save and Connect"].click()
        let window = app.windows["Tunneled — catalog"]
        XCTAssertTrue(window.staticTexts["country"].waitForExistence(timeout: 10))
        window.staticTexts["country"].doubleClick()
        XCTAssertTrue(window.staticTexts["Czechia"].waitForExistence(timeout: 5))
        window.typeKey("w", modifierFlags: .command)
        let profiles = try String(contentsOf: directory.appending(path: "connections.json"), encoding: .utf8)
        XCTAssertFalse(profiles.contains("local-fixture"))
        XCTAssertFalse(profiles.contains("tunnel-fixture"))
    }
}
