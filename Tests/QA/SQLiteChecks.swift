import Foundation
import Synchronization

@main struct DriverCheck {
    static func check(_ ok: Bool, _ label: String) throws {
        guard ok else { throw BrowserError("FAIL: " + label) }; print("PASS: " + label)
    }
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    private static func run() async throws {
        let path = CommandLine.arguments[1]
        var profile = ConnectionProfile(); profile.driver = .sqlite; profile.filePath = path
        let s = DatabaseSession()
        let target = try await s.open(profile, password: "")
        let objs = try await s.objects()
        let city = DatabaseObject(name: "mesto", kind: .table)
        try check(Set(objs) == [city, DatabaseObject(name: "zeme", kind: .table),
                                DatabaseObject(name: "v_mesta", kind: .view)], "two tables and one view")
        let schema = try await s.schema(of: city, driver: .sqlite)
        try check(schema.columns.map(\.name) == ["id","nazev","kod_zeme","poznamka"], "four columns with original names")
        let page = try await s.page(of: city, filters: [], sortColumn: nil, descending: false, offset: 0, limit: 2, keyColumns: ["id"])
        try check(page.count == 3 && page.result.rows.count == 2 && page.result.rows[0][3] == .null && page.result.rows[1][1] == .text("Košice"), "count, pagination, UTF-8, NULL")
        let last = try await s.page(of: city, filters: [], sortColumn: nil, descending: false, offset: 2, limit: 2, keyColumns: ["id"])
        try check(last.result.rows.map { $0[3] } == [.text("")], "empty string on last page")
        let filtered = try await s.page(of: city, filters: [.init(column:"poznamka",operation:.isNull)], sortColumn:nil, descending:false, offset:0,limit:10,keyColumns:["id"])
        try check(filtered.result.rows.map { $0[1] } == [.text("Brno")], "IS NULL excludes empty text")
        try check(filtered.count == 1 && filtered.statements.count == 1, "short filtered first page has an exact total without a COUNT query")
        let pastEnd = try await s.page(of: city, filters: [], sortColumn: nil, descending: false, offset: 100, limit: 2, keyColumns: ["id"])
        try check(pastEnd.offset == 2 && pastEnd.count == 3 && pastEnd.result.rows == last.result.rows, "an out-of-range page still returns the last page")
        func execute(_ sql: String) async throws -> QueryResult {
            try await s.runUserSQL(sql, on: target, cancellation: QueryCancellation(), limit: 50).results[0]
        }
        _ = try await execute("CREATE TEMP VIEW qa_count_failure AS SELECT id FROM mesto WHERE CASE id WHEN 3 THEN abs(-9223372036854775808) ELSE 1 END")
        let preview = Mutex<[[SQLValue]]>([])
        var countFailed = false
        do {
            _ = try await s.page(of: DatabaseObject(name: "qa_count_failure", kind: .view), filters: [], sortColumn: nil,
                                 descending: false, offset: 0, limit: 2, keyColumns: ["id"]) { result in
                preview.withLock { $0 = result.rows }
            }
        } catch { countFailed = error.localizedDescription.contains("overflow") }
        try check(countFailed && preview.withLock { $0 == [[.integer("1")], [.integer("2")]] },
                  "the first two rows are delivered before COUNT reaches the failing third record")
        try check(try await execute("SELECT count(*) AS n FROM mesto").rows == [[.integer("3")]], "SQL count = 3")
        try check(try await execute("SELECT nazev FROM mesto ORDER BY id").rows.map { $0[0].display } == ["Brno","Košice","Graz"], "ordered city names")
        var failed = false
        do { _ = try await execute("SELECT * FROM qa_missing") } catch { failed = error.localizedDescription.contains("qa_missing") }
        try check(failed && !target.isEmpty, "missing table rejected")
        try check(try await execute("SELECT 42 AS answer").rows == [[.integer("42")]], "same connection recovers")
        try check(try await execute("UPDATE mesto SET poznamka='QA' WHERE id=1").affectedRows == 1, "one changed row")
        try check(try await execute("SELECT poznamka FROM mesto WHERE id=1").rows == [[.text("QA")]], "persisted QA note")
        try check(try await execute("UPDATE mesto SET poznamka=NULL WHERE id=1").affectedRows == 1, "restore original NULL")
        let ddl = try await execute("CREATE TEMP TABLE qa_empty(value TEXT)")
        try check(ddl.affectedRows == 0, "empty CREATE TABLE after UPDATE: expected 0, got " + String(ddl.affectedRows))
        _ = try await execute("CREATE TEMP TRIGGER qa_trigger AFTER UPDATE ON mesto BEGIN INSERT INTO qa_empty VALUES ('log'); END")
        let touched = try await execute("UPDATE mesto SET poznamka=NULL WHERE id=1")
        try check(touched.affectedRows == 1, "report only the directly updated row, excluding the trigger")
        let output = URL(fileURLWithPath: path).deletingLastPathComponent().appending(path: "notes.csv")
        var csv = CSVSettings(); csv.header = true; csv.delimiter = ","; csv.quote = "\""; csv.nullToken = "\\N"
        let notes: [[SQLValue]] = [[.text("A\r\nB")], [.text("Left\nRight")], [.null], [.text("")]]
        func roundTrip(_ options: CSVSettings) async throws -> [[SQLValue]] {
            let request = ExportRequest(destination: output, overwrite: true, driver: .sqlite, format: .csv,
                scope: .result, csv: options, object: nil, columns: ["note"], rows: notes,
                read: nil, includeDDL: false, includeData: true, includeDrop: false, outputTable: "notes")
            _ = try await s.export(request)
            return try CSVDocument(file: output, settings: options).preview().rows
        }
        let reopened = try await roundTrip(csv)
        try check(reopened == notes, "CSV round trip: preserve CRLF, LF, NULL and empty text. Got " + String(reflecting: reopened.map { $0.map(\.display) }))
        csv.flattenLineBreaks = true
        let flattened = try await roundTrip(csv)
        try check(flattened == [[.text("A B")], [.text("Left Right")], [.null], [.text("")]], "flatten only embedded line breaks, one space per CRLF")
        csv.flattenLineBreaks = false; csv.nullToken = ""; csv.lineEnding = "CRLF"
        let blankNulls = try await roundTrip(csv)
        try check(blankNulls == notes, "one-column empty NULL token distinct from quoted empty text")
        await s.close()
    }
}
