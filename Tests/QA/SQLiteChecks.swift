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
    private static func checkSSHAddresses() throws {
        let full = try ProfileAddress.parse("mysql+ssh://jump:s%40s@qa-alias:2222/reader:d%3A%40%2F%25@[::1]:3307/catalog%20qa")
        try check(full.profile.ssh?.host == "qa-alias" && full.profile.ssh?.port == "2222" && full.profile.ssh?.user == "jump" && full.sshPassword == "s@s",
                  "TablePlus SSH credentials are distinct from database credentials")
        try check(full.profile.host == "[::1]" && full.profile.port == "3307" && full.profile.database == "catalog qa" && full.profile.user == "reader" && full.password == "d:@/%",
                  "inner IPv6 endpoint and URL-encoded database credentials decode once")
        let short = try ProfileAddress.parse("mariadb+ssh://jump@qa-alias/reader:d%40b")
        try check(short.profile.host == "127.0.0.1" && short.profile.port == "3306" && short.profile.database.isEmpty && short.profile.user == "reader" && short.password == "d@b" && short.profile.ssh?.port == "",
                  "compact URL imports database credentials for the SSH server's loopback address")
        let tablePlus = try ProfileAddress.parse("mariadb+ssh://jump@qa-alias/reader:d%40b@db/catalog?statusColor=FFD7D4&enviroment=production&name=qa%40db&tLSMode=0&usePrivateKey=true&safeModeLevel=0&advancedSafeModeLevel=0")
        try check(tablePlus.profile.usesPreferredTLS && tablePlus.profile.ssh?.keyOnly == true && tablePlus.profile.database == "catalog" && tablePlus.profile.host == "db" && tablePlus.profile.name == "qa@db" && tablePlus.profile.environment == "production" && tablePlus.profile.tagColor == "#FFD7D4",
                  "TablePlus export preserves preferred TLS, key authentication, production tag, name and status color")
        let copied = try ProfileAddress.url(tablePlus.profile).map { try ProfileAddress.parse($0.absoluteString) }
        try check(copied?.profile.usesPreferredTLS == true && copied?.profile.ssh?.keyOnly == true && copied?.profile.environment == "production" && copied?.profile.tagColor == "#FFD7D4", "copying the profile retains imported settings")
        let inherited = try ProfileAddress.parse("mariadb://reader@localhost/catalog?ssh-host=qa-alias")
        try check(inherited.profile.ssh?.user == "" && inherited.profile.ssh?.port == "", "omitted SSH settings inherit config even in legacy URLs")
        let exported = try ProfileAddress.url(full.profile).map { try ProfileAddress.parse($0.absoluteString) }
        try check(exported?.profile.ssh == full.profile.ssh && exported?.profile.database == full.profile.database && exported?.password == "" && exported?.sshPassword == "",
                  "copying an SSH connection URL preserves its endpoint and omits both passwords")
        for url in ["mariadb+ssh://qa-alias:65536/reader:dummy", "mysql+ssh://qa-alias/reader:dummy@db:99999999999999999999999/catalog",
                    "mariadb+ssh://qa-alias/reader:dummy@/catalog", "mariadb+ssh://qa-alias/reader:dummy#fragment"] {
            do { _ = try ProfileAddress.parse(url) }
            catch { try check(!error.localizedDescription.contains("dummy"), "invalid SSH URL rejected without exposing credentials"); continue }
            throw BrowserError("FAIL: malformed SSH URL accepted")
        }
    }
    @MainActor private static func checkWorkspace(profile: ConnectionProfile, session: DatabaseSession, database: String, support: URL) async throws {
        func open(_ p: ConnectionProfile) async -> Workspace {
            let w = Workspace(profile: p, session: session, database: database, password: "", sshPassword: "",
                              notebook: QueryNotebook(directory: support, profile: p.id))
            await w.start()
            return w
        }
        let first = await open(profile)
        await first.open(DatabaseObject(name: "mesto", kind: .table))
        guard let table = first.active else { throw BrowserError("Missing fixture tab") }
        table.filters = [ColumnFilter(column: "id", operation: .equals, value: "2")]
        await first.applyFilters(table)
        table.sortColumn = "nazev"; table.descending = true; table.hiddenColumns = ["poznamka"]
        first.newQuery(text: "DELETE FROM mesto")
        first.consoleHeight = 185
        first.rememberOnClose()
        let other = await open({ var copy = profile; copy.id = UUID(); return copy }())
        try check(other.tabs.isEmpty, "connections do not share their remembered tabs")
        let restored = await open(profile)
        try check(restored.tabs.count == 2 && restored.active?.sql == "DELETE FROM mesto" && restored.active?.executions.isEmpty == true && restored.consoleHeight == 185,
                  "workspace restores tab order, active SQL editor and layout without executing SQL")
        let reopened = restored.tabs[0]
        try check(reopened.result.rows.isEmpty && reopened.needsTableLoad, "background tables are not queried on reopen")
        await restored.loadRestoredTab(reopened)
        try check(reopened.result.rows.count == 1 && reopened.result.rows.first?.first == .integer("2") && reopened.sortColumn == "nazev" && reopened.descending && reopened.hiddenColumns == ["poznamka"],
                  "table data is fetched with the remembered filter, sort and columns")
        restored.closeTabs(restored.tabs)
        restored.rememberOnClose()
        try check((await open(profile)).tabs.isEmpty, "closing all tabs replaces the old session with an empty one")
    }

    private static func run() async throws {
        try checkSSHAddresses()
        let path = CommandLine.arguments[1]
        let support = URL(filePath: path).deletingLastPathComponent().appending(path: "Application Support")
        let legacy = support.appending(path: "ConnectionBrowser", directoryHint: .isDirectory)
        try check(ConnectionLibrary.defaultDirectory(in: support).lastPathComponent == "TableExplorer", "new installations use the TableExplorer library")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try check(ConnectionLibrary.defaultDirectory(in: support) == legacy, "upgrades reuse the existing connection library")
        var profile = ConnectionProfile(); profile.driver = .sqlite; profile.filePath = path
        let s = DatabaseSession()
        let target = try await s.open(profile, password: "")
        try await checkWorkspace(profile: profile, session: s, database: target, support: support)
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
