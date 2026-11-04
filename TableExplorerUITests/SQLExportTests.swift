import XCTest
import SQLite3

final class SQLExportTests: XCTestCase {
    @MainActor
    func testCompressedSQLRecreatesRowsAndIndex() throws {
        continueAfterFailure = false
        let app = XCUIApplication(), fm = FileManager.default
        let directory = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { app.terminate(); try? fm.removeItem(at: directory) }
        let db = directory.appending(path: "export.sqlite"), output = directory.appending(path: "mesto.sql.gz")
        try SQLiteFixture.create(at: db)
        app.launchEnvironment["CONNECTION_BROWSER_LIBRARY"] = directory.path; app.launch()
        app.buttons["New Connection"].click(); app.buttons["Import from URL"].click()
        app.textFields["Connection URL"].replaceText(with: db.absoluteString); app.buttons["Import"].click(); app.buttons["Save and Connect"].click()
        let window = app.windows["export — export.sqlite"]
        XCTAssertTrue(window.staticTexts["mesto"].waitForExistence(timeout: 5))
        window.staticTexts["mesto"].doubleClick()
        XCTAssertTrue(window.buttons["Export Data"].waitForExistence(timeout: 5))
        window.buttons["Export Data"].click(); app.radioButtons["SQL"].click()
        app.checkBoxes["Schema"].click(); app.checkBoxes["DROP statement"].click(); app.checkBoxes["Compress with gzip"].click()
        app.textFields["Destination File"].replaceText(with: output.path); app.buttons["Write Export"].click()
        XCTAssertTrue(app.buttons["Write Export"].waitForNonExistence(timeout: 6))
        XCTAssertTrue(try Data(contentsOf: output).starts(with: [0x1f, 0x8b]))
        let gzip = Process(), pipe = Pipe()
        gzip.executableURL = URL(filePath: "/usr/bin/gzip"); gzip.arguments = ["-dc", output.path]; gzip.standardOutput = pipe
        try gzip.run(); let sql = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        gzip.waitUntilExit(); XCTAssertEqual(gzip.terminationStatus, 0)
        XCTAssertTrue(sql.hasPrefix("DROP TABLE IF EXISTS"))
        var copy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &copy), SQLITE_OK)
        defer { sqlite3_close(copy) }
        XCTAssertEqual(sqlite3_exec(copy, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(copy)))
        var statement: OpaquePointer?
        let verify = "SELECT count(*), sum(poznamka IS NULL), sum(poznamka = ''), (SELECT count(*) FROM pragma_index_list('mesto') WHERE name='ix_mesto_zeme') FROM mesto"
        XCTAssertEqual(sqlite3_prepare_v2(copy, verify, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual((0..<4).map { sqlite3_column_int(statement, $0) }, [3, 1, 1, 1])
    }
}
