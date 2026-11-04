import XCTest

final class ServerAccountTests: XCTestCase {
    @MainActor
    func testAccountReviewGrantRevokeAndRemovalAgainstAnIndependentLogin() throws {
        try XCTSkipUnless(fixtureListening(33462), "Start the TLS fixture with the account-management seed.")
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: dir) }
        let ca = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/TLSFixture/ca.crt")
        let binaries = ["/opt/homebrew/opt/mysql-client@8.4/bin/mysql", "/opt/homebrew/opt/mysql-client/bin/mysql", "/opt/homebrew/bin/mysql", "/opt/homebrew/bin/mariadb"]
        let client = try XCTUnwrap(binaries.first(where: fm.isExecutableFile(atPath:)))
        let user = "cb_ui_" + UUID().uuidString.prefix(8).lowercased()
        let secret = "Demo'with\\slash12!"
        let options = dir.appending(path: "test.cnf")
        XCTAssertTrue(fm.createFile(atPath: options.path, contents: Data(("[client]\npassword=\"" + secret.replacingOccurrences(of: "\\", with: "\\\\") + "\"\n").utf8), attributes: [.posixPermissions: 0o600]))
        func readNotes() throws -> (Int32, String) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/arch")
            process.arguments = ["-arm64", client, "--defaults-file=" + options.path, "--protocol=TCP", "-h127.0.0.1", "-P33462", "-u" + user,
                                 "--ssl-ca=" + ca.path, "-N", "-e", "SELECT body FROM backup_demo.notes WHERE id=1"]
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit(); return (process.terminationStatus, message)
        }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = dir.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: "mariadb://fixture_admin:fixture-admin-only@127.0.0.1:33462/backup_demo?name=Administration")
        app.buttons["Import"].click(); app.textFields["CA Certificate Path"].replaceText(with: ca.path)
        app.buttons["Save and Connect"].click()
        let window = app.windows["Administration — backup_demo"]
        XCTAssertTrue(window.staticTexts["notes"].waitForExistence(timeout: 6))
        app.menuBars.menuBarItems["Database"].click(); app.menuItems["Server Accounts…"].click()
        let search = app.textFields["Server Tool Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.replaceText(with: user)
        let account = app.staticTexts[user].firstMatch
        let menu = app.descendants(matching: .any).matching(identifier: "Manage Account").firstMatch
        menu.click(); app.menuItems["Create Account…"].click()
        app.textFields["Account Name"].replaceText(with: user); app.textFields["Account Host"].replaceText(with: "%")
        app.secureTextFields["New Password"].replaceText(with: secret)
        app.buttons["Review Account Change"].click()
        XCTAssertFalse((app.staticTexts["accountPreview"].value as? String ?? "").contains(secret))
        app.buttons["Apply Account Change"].click()
        XCTAssertTrue(account.waitForExistence(timeout: 5), app.staticTexts["accountError"].description)
        var probe = try readNotes()
        XCTAssertNotEqual(probe.0, 0)
        XCTAssertTrue(probe.1.contains("1142") || probe.1.contains("1044"), probe.1)
        for grant in [true, false] {
            account.click(); menu.click(); app.menuItems[grant ? "Grant Privileges…" : "Revoke Privileges…"].click()
            app.checkBoxes["SELECT"].click(); app.buttons["Review Account Change"].click()
            XCTAssertTrue((app.staticTexts["accountPreview"].value as? String)?.contains(user) == true)
            app.buttons["Apply Account Change"].click()
            XCTAssertTrue(app.buttons["Apply Account Change"].waitForNonExistence(timeout: 5))
            probe = try readNotes()
            if grant { XCTAssertEqual(probe.0, 0, probe.1); XCTAssertEqual(probe.1.trimmingCharacters(in: .whitespacesAndNewlines), "Original") }
            else { XCTAssertNotEqual(probe.0, 0); XCTAssertTrue(probe.1.contains("1142") || probe.1.contains("1044"), probe.1) }
        }
        account.click(); menu.click(); app.menuItems["Remove Account…"].click()
        app.buttons["Review Account Change"].click()
        XCTAssertFalse(app.buttons["Apply Account Change"].isEnabled)
        app.textFields["Confirm Account"].replaceText(with: user + "@%")
        app.buttons["Apply Account Change"].click()
        XCTAssertTrue(account.waitForNonExistence(timeout: 5))
        probe = try readNotes()
        XCTAssertNotEqual(probe.0, 0); XCTAssertTrue(probe.1.contains("1045"), probe.1)
    }
}
