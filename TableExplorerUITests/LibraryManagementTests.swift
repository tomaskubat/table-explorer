import XCTest

final class LibraryManagementTests: XCTestCase {
    @MainActor
    func testLongImportedPasswordsStayInsideConnectionSheet() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        func frames(_ password: String) -> [CGRect] {
            app.buttons["New Connection"].click()
            app.buttons["Import from URL"].click()
            let sheet = app.sheets.firstMatch
            let address = app.textFields["Connection URL"]
            address.replaceText(with: "mariadb+ssh://jump:" + password + "@bastion/reader:" + password + "@db/catalog?tLSMode=0&usePrivateKey=true&enviroment=production&name=reader%40qa")
            let initial = address.frame
            app.buttons["Import"].click()
            let db = app.secureTextFields["Password"]
            XCTAssertTrue(db.waitForExistence(timeout: 5))
            db.click()
            let dbFields = [db, app.textFields["Connection Name"], app.textFields["Host"], app.textFields["Port"], app.textFields["User"], app.buttons["Save"]]
            func frame(_ field: XCUIElement) -> CGRect {
                let rect = CGRect(x: field.frame.minX - sheet.frame.minX, y: 0, width: field.frame.width, height: field.frame.height)
                XCTAssertGreaterThanOrEqual(rect.minX, 10, "Field lies outside the sheet margin")
                XCTAssertLessThanOrEqual(rect.maxX, sheet.frame.width - 10, "Field lies outside the sheet margin")
                return rect
            }
            let database = dbFields.map(frame)
            app.radioButtons["SSH Tunnel"].click()
            let ssh = app.secureTextFields["SSH Password"]
            ssh.click()
            let result = [CGRect(origin: .zero, size: initial.size)] + database + [frame(ssh), frame(app.textFields["SSH Host"])]
            XCTAssertTrue(app.buttons["Save"].isHittable)
            app.buttons["Cancel"].click()
            return result
        }
        let normal = frames("fixture"), long = frames(String(repeating: "fixture", count: 120))
        for (a, b) in zip(normal, long) {
            XCTAssertEqual(a.minX, b.minX, accuracy: 2, "Long credentials must not shift controls")
            XCTAssertEqual(a.width, b.width, accuracy: 2, "Input width must not depend on the password")
        }
    }

    @MainActor
    func testImportingAURLAndExplicitlyCreatingANewSQLiteFile() throws {
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        app.buttons["New Connection"].click()
        app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: "mariadb://reader:never-export@localhost:3307/catalog")
        app.buttons["Import"].click()
        XCTAssertTrue(app.textFields["Connection Name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["User"].value as? String, "reader")
        XCTAssertEqual(app.textFields["Port"].value as? String, "3307")
        app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["reader@localhost"].waitForExistence(timeout: 5))
        let library = try String(contentsOf: directory.appending(path: "connections.json"), encoding: .utf8)
        XCTAssertFalse(library.contains("never-export"))

        app.newProfile(driver: "SQLite")
        app.textFields["Connection Name"].replaceText(with: "Created File")
        let file = directory.appending(path: "new.sqlite")
        app.textFields["Database File"].replaceText(with: file.path)
        app.buttons["Create SQLite File…"].click()
        app.buttons["Create File"].click()
        XCTAssertTrue(app.staticTexts["Database file created"].waitForExistence(timeout: 4))
        let original = try Data(contentsOf: file)
        XCTAssertTrue(original.starts(with: Data("SQLite format 3".utf8)))
        app.buttons["Create SQLite File…"].click()
        app.buttons["Create File"].click()
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 4))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testGroupAndProfileMenusMoveAStoredMariaDBLoginWithoutLosingItsPassword() throws {
        try XCTSkipUnless(fixtureListening(33461), "Start the MariaDB fixture.")
        continueAfterFailure = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = XCUIApplication()
        defer { app.terminate(); try? FileManager.default.removeItem(at: directory) }
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path
        app.launch()
        let window = app.windows["Saved Connections"]
        for name in ["Development", "Archive"] {
            window.buttons["New Group"].click()
            let input = app.textFields["Group Name"]
            XCTAssertTrue(input.waitForExistence(timeout: 4))
            input.replaceText(with: name)
            app.buttons["Save"].click()
            XCTAssertTrue(window.staticTexts[name].waitForExistence(timeout: 4))
        }
        window.staticTexts["Development"].click()
        app.newProfile(driver: "MariaDB")
        XCTAssertTrue(app.textFields["Connection Name"].waitForExistence(timeout: 4))
        app.textFields["Connection Name"].replaceText(with: "Move Me")
        app.textFields["User"].replaceText(with: "browser")
        app.textFields["Port"].replaceText(with: "33461")
        app.textFields["Database"].replaceText(with: "catalog")
        app.secureTextFields["Password"].replaceText(with: "local-fixture")
        app.checkBoxes["Remember password in Keychain"].click()
        app.checkBoxes["Require verified TLS"].setChecked(false)
        app.buttons["Save"].click()
        XCTAssertTrue(window.staticTexts["Move Me"].waitForExistence(timeout: 5))
        window.staticTexts["Development"].click()
        app.newProfile(driver: "SQLite")
        app.textFields["Connection Name"].replaceText(with: "Local File")
        let source = directory.appending(path: "local.sqlite")
        try SQLiteFixture.create(at: source)
        app.textFields["Database File"].replaceText(with: source.path)
        app.buttons["Save"].click()
        XCTAssertTrue(window.staticTexts["Local File"].waitForExistence(timeout: 4))

        window.staticTexts["Development"].rightClick()
        XCTAssertFalse(app.menuItems["Connect"].isEnabled)
        XCTAssertFalse(window.menuItems["Duplicate"].isEnabled)
        XCTAssertFalse(app.menuItems["Copy as URL"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        window.staticTexts["Move Me"].rightClick()
        XCTAssertTrue(app.menuItems["Connect"].isEnabled)
        XCTAssertTrue(window.menuItems["Duplicate"].isEnabled)
        XCTAssertTrue(app.menuItems["Copy as URL"].isEnabled)
        app.menuItems["Move to…"].click()
        app.menuItems["Archive"].click()

        let persisted = try String(contentsOf: directory.appending(path: "connections.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("local-fixture"))
        app.terminate(); app.launch()
        let profile = window.staticTexts["Move Me"]
        XCTAssertTrue(profile.waitForExistence(timeout: 4))
        XCTAssertGreaterThan(profile.frame.minY, window.staticTexts["Archive"].frame.minY)
        XCTAssertLessThan(window.staticTexts["Local File"].frame.minY, window.staticTexts["Archive"].frame.minY)
        profile.doubleClick()
        let connected = app.windows["Move Me — catalog"]
        XCTAssertTrue(connected.staticTexts["country"].waitForExistence(timeout: 8))
        connected.typeKey("w", modifierFlags: .command)
        profile.rightClick()
        app.menuItems["Remove…"].click()
        app.buttons["Remove"].click()
        XCTAssertTrue(profile.waitForNonExistence(timeout: 5))
    }
}
