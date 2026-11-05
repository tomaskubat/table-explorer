import AppKit
import XCTest

/// Opt-in: exercise the two distribution archives, without Xcode re-signing either app.
final class SignedUpgradeTests: XCTestCase {
    @MainActor func testSavedPasswordAcrossSignedBuilds() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TABLEEXPLORER_SIGNING_QA"] != nil,
                          "Supply a directory containing signed A.zip and B.zip via TEST_RUNNER_TABLEEXPLORER_SIGNING_QA.")
        let inputs = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["TABLEEXPLORER_SIGNING_QA"]))
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        let library = root.appending(path: "library"), url = root.appending(path: "TableExplorer.app")
        try XCTSkipUnless(NSRunningApplication.runningApplications(withBundleIdentifier: "local.connectionbrowser.app").isEmpty,
                          "Quit the installed TableExplorer before exercising release builds.")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let name = "Signing QA", id = UUID(), group = UUID()
        func tool(_ path: String, _ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        func install(_ archive: String) throws {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try tool("/usr/bin/ditto", ["-x", "-k", inputs.appending(path: archive + ".zip").path, root.path])
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            try tool(repo.appending(path: "Scripts/app-signature.sh").path, ["verify", url.path])
        }
        func app() -> XCUIApplication {
            let release = XCUIApplication(url: url)
            release.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = library.path
            release.launchArguments = ["-SUEnableAutomaticChecks", "NO"]
            return release
        }
        let database = library.appending(path: "qa.sqlite")
        try SQLiteFixture.create(at: database)
        func profile(_ driver: String) throws {
            let entry: [String: Any] = ["id":id.uuidString, "name":name, "driver":driver, "environment":"local",
                "host":"127.0.0.1","port":"3306","user":"qa","database":"","socketPath":"","usesSocket":false,
                "verifyTLS":false,"caPath":"","filePath":database.path,"rememberPassword":driver == "SQLite"]
            try JSONSerialization.data(withJSONObject: [["id":group.uuidString,"name":"Test","connections":[entry]]])
                .write(to: library.appending(path:"connections.json"),options:.atomic)
        }
        // Create a synthetic credential through A, giving it the same ownership as a real saved password.
        try profile("MariaDB"); try install("A")
        let a = app(); defer { a.terminate() }; a.launch()
        let saved = a.windows["Saved Connections"].staticTexts[name]
        saved.rightClick(); a.menuItems["Edit Connection…"].click()
        a.secureTextFields["Password"].click(); a.typeText("signing-qa-test-value")
        a.checkBoxes["Remember password in Keychain"].setChecked(true); a.buttons["Save"].click()
        defer {
            // Remove only the item created by this run; never read it into the test process.
            try? tool("/usr/bin/security", ["delete-generic-password","-s","local.connectionbrowser.database","-a",id.uuidString])
        }
        XCTAssertTrue(a.sheets.firstMatch.waitForNonExistence(timeout: 5))
        try tool("/usr/bin/security", ["find-generic-password","-s","local.connectionbrowser.database","-a",id.uuidString])
        a.terminate()
        // SQLite opens locally; connectSaved still reads the same keychain item by UUID.
        try profile("SQLite")
        func connectTwice(_ release: XCUIApplication, _ version: String) {
            release.launch()
            let workspace = release.windows["Signing QA — qa.sqlite"]
            for attempt in 1...2 {
                XCTContext.runActivity(named: "\(version): open saved connection \(attempt)") { _ in
                    release.windows["Saved Connections"].staticTexts[name].doubleClick()
                    XCTAssertTrue(workspace.staticTexts["mesto"].waitForExistence(timeout: 8))
                    workspace.buttons[XCUIIdentifierCloseWindow].click()
                    XCTAssertTrue(workspace.waitForNonExistence(timeout: 4))
                }
            }
            release.terminate()
        }
        connectTwice(a, "A")
        try install("B")
        let b = app(); defer { b.terminate() }
        connectTwice(b, "B")
    }
}
