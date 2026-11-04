import XCTest

final class SSHTunnelTests: XCTestCase {
    @MainActor
    func testImportsTablePlusURLAndConnectsUsingIncludedSSHAlias() throws {
        try exerciseImportedURL(passwordAuth: false)
    }

    @MainActor
    func testImportsBothPasswordsAndOverridesSSHConfigUserAndPort() throws {
        try exerciseImportedURL(passwordAuth: true)
    }

    @MainActor
    private func exerciseImportedURL(passwordAuth: Bool) throws {
        // The second server requires database TLS, independently of SSH.
        let port: UInt16 = passwordAuth ? 33464 : 33463
        try XCTSkipUnless(fixtureListening(port), "Run sh Tests/Fixtures/SSH/start-ssh.sh")
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/SSHFixture")
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hosts = directory.appending(path: "hosts")
        let config = directory.appending(path: "config")
        try """
        Host qa-bastion
            HostName 127.0.0.1
            Port \(passwordAuth ? "1" : "33463")
            User \(passwordAuth ? "wrong-user" : "tunnel")
            PreferredAuthentications \(passwordAuth ? "password" : "publickey")
            IdentitiesOnly yes
            IdentityFile "\(fixture.appending(path: "client").path)"
            UserKnownHostsFile "\(fixture.appending(path: "known_hosts").path)"
        """.write(to: hosts, atomically: true, encoding: .utf8)
        try "Include \"\(hosts.path)\"\n".write(to: config, atomically: true, encoding: .utf8)
        app.launchEnvironment["TABLE_EXPLORER_SSH_CONFIG"] = config.path
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        app.buttons["New Connection"].click()
        app.buttons["Import from URL"].click()
        let server = passwordAuth ? "tunnel:tunnel-fixture@qa-bastion:\(port)" : "qa-bastion"
        let options = "statusColor=FFD7D4&enviroment=production&name=reader%40qa&tLSMode=0&usePrivateKey=\(!passwordAuth)&safeModeLevel=0&advancedSafeModeLevel=0"
        app.textFields["Connection URL"].replaceText(with: "mariadb+ssh://" + server + "/browser:local-fixture@database/catalog?" + options)
        app.buttons["Import"].click()
        XCTAssertTrue(app.textFields["Connection Name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["User"].value as? String, "browser")
        XCTAssertEqual(app.textFields["Database"].value as? String, "catalog")
        XCTAssertEqual(app.textFields["Connection Name"].value as? String, "reader@qa")
        XCTAssertEqual(app.popUpButtons["Connection Tag"].value as? String, "production")
        XCTAssertTrue(app.buttons["Save and Connect"].isEnabled)
        app.buttons["Save and Connect"].click()
        let table = app.windows.containing(.staticText, identifier: "country").staticTexts["country"].firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15), app.staticTexts["connectionError"].exists ? String(describing: app.staticTexts["connectionError"].value) : "No database workspace")
        table.doubleClick()
        XCTAssertTrue(app.staticTexts["Czechia"].waitForExistence(timeout: 5))
        let saved = try String(contentsOf: directory.appending(path: "connections.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("local-fixture"))
        XCTAssertFalse(saved.contains("tunnel-fixture"))
        XCTAssertTrue(saved.contains("qa-bastion"))
    }

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
        if !tls { app.checkBoxes["Require verified TLS"].setChecked(false) }
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
