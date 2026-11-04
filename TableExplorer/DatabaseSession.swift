import CMariaDB
import Foundation
import Darwin
import SQLite3

enum SQLValue: Hashable, Sendable {
    case null, text(String), integer(String), number(String), blob(Data)

    var display: String {
        switch self {
        case .null: "NULL"
        case .text(let text), .integer(let text), .number(let text): text
        case .blob(let bytes): "0x" + bytes.map { String(format: "%02X", $0) }.joined()
        }
    }
}

struct QueryResult: Sendable {
    var columns: [String] = []
    var rows: [[SQLValue]] = []
    var affectedRows: Int64 = 0
    var truncated = false
}

struct DatabaseObject: Hashable, Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case table = "Table", view = "View", procedure = "Procedure", function = "Function" }
    let name: String
    let kind: Kind
    var id: Self { self }
}

final class MariaHandle {
    let connection: UnsafeMutablePointer<MYSQL>
    init() throws {
        guard let handle = mysql_init(nil) else { throw BrowserError("Could not allocate a MariaDB connection.") }
        connection = handle
    }
    deinit { mysql_close(connection) }

    func open(_ profile: ConnectionProfile, password: String) throws {
        var timeout = UInt32(BrowserPreferences.timeout)
        var mode = profile.usesSocket ? MYSQL_PROTOCOL_SOCKET : MYSQL_PROTOCOL_TCP
        mysql_options(connection, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)
        mysql_options(connection, MYSQL_OPT_PROTOCOL, &mode)
        mysql_options(connection, MYSQL_SET_CHARSET_NAME, "utf8mb4")
        var localInfile: UInt32 = 0
        mysql_options(connection, MYSQL_OPT_LOCAL_INFILE, &localInfile)
        var tls: my_bool = profile.verifyTLS ? 1 : 0
        mysql_options(connection, MYSQL_OPT_SSL_ENFORCE, &tls)
        mysql_options(connection, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &tls)
        if profile.verifyTLS, let ssh = profile.ssh {
            // Connector/C sees a local socket behind OpenSSH. Pin the remote
            // database certificate explicitly rather than verifying localhost.
            let pin = ssh.databaseFingerprint.replacingOccurrences(of: ":", with: "")
            guard pin.count == 64, pin.allSatisfy(\.isHexDigit) else {
                throw BrowserError("Enter the remote database certificate's SHA-256 fingerprint to use verified TLS through SSH.")
            }
            guard mysql_options(connection, MARIADB_OPT_TLS_PEER_FP, pin) == 0 else { throw failure() }
        } else if profile.verifyTLS {
            // Connector/C can accept a local peer using zero-configuration TLS
            // when no trust anchor is specified. This mode promises CA validation.
            let ca = profile.caPath.isEmpty ? "/etc/ssl/cert.pem" : profile.caPath
            guard mysql_options(connection, MYSQL_OPT_SSL_CA, ca) == 0 else { throw failure() }
        }
        guard profile.usesSocket || UInt16(profile.port).map({ $0 > 0 }) == true else { throw BrowserError("Enter a port between 1 and 65535.") }
        let server = profile.usesSocket ? "localhost" : profile.host
        let connected = mysql_real_connect(connection, server, profile.user, password,
            profile.database.isEmpty ? nil : profile.database, UInt32(profile.port) ?? 0,
            profile.usesSocket ? profile.socketPath : nil, 0)
        guard connected != nil else { throw failure() }
        if profile.verifyTLS && mysql_get_ssl_cipher(connection) == nil { throw BrowserError("The server did not establish a TLS connection.") }
    }

    static func value(_ data: Data, field: MYSQL_FIELD) -> SQLValue {
        switch field.type {
        case MYSQL_TYPE_TINY, MYSQL_TYPE_SHORT, MYSQL_TYPE_LONG, MYSQL_TYPE_LONGLONG, MYSQL_TYPE_INT24, MYSQL_TYPE_YEAR:
            return .integer(String(decoding: data, as: UTF8.self))
        case MYSQL_TYPE_FLOAT, MYSQL_TYPE_DOUBLE, MYSQL_TYPE_DECIMAL, MYSQL_TYPE_NEWDECIMAL:
            return .number(String(decoding: data, as: UTF8.self))
        default:
            if field.charsetnr == 63 && [MYSQL_TYPE_BLOB, MYSQL_TYPE_LONG_BLOB, MYSQL_TYPE_MEDIUM_BLOB, MYSQL_TYPE_TINY_BLOB, MYSQL_TYPE_BIT, MYSQL_TYPE_VAR_STRING, MYSQL_TYPE_STRING].contains(field.type) {
                return .blob(data)
            }
            return .text(String(decoding: data, as: UTF8.self))
        }
    }

    func failure() -> BrowserError {
        BrowserError.maria(mysql_errno(connection), String(cString: mysql_error(connection)))
    }

    func query(_ sql: String, limit: Int, visit: (([SQLValue]) throws -> Void)? = nil,
               receiveResult: ((QueryResult) -> Void)? = nil) throws -> QueryResult {
        guard mysql_real_query(connection, sql, UInt(sql.utf8.count)) == 0 else { throw failure() }
        var result = QueryResult()
        var more: Int32
        repeat {
            if let cursor = mysql_use_result(connection) {
                defer { mysql_free_result(cursor) }
                let count = Int(mysql_num_fields(cursor))
                let fields = mysql_fetch_fields(cursor)!
                result = QueryResult(columns: (0..<count).map { String(cString: fields[$0].name) })
                while let row = mysql_fetch_row(cursor) {
                    guard result.rows.count < limit else { result.truncated = true; continue }
                    let lengths = mysql_fetch_lengths(cursor)!
                    let values: [SQLValue] = (0..<count).map { i in
                        guard let bytes = row[i] else { return .null }
                        let data = Data(bytes: bytes, count: Int(lengths[i]))
                        let field = fields[i]
                        return Self.value(data, field: field)
                    }
                    if let visit { try visit(values) } else { result.rows.append(values) }
                }
                if mysql_errno(connection) != 0 { throw failure() }
                receiveResult?(result)
            } else if mysql_field_count(connection) != 0 {
                throw failure()
            } else {
                result.affectedRows = Int64(bitPattern: mysql_affected_rows(connection))
            }
            more = mysql_next_result(connection)
        } while more == 0
        if more > 0 { throw failure() }
        return result
    }
}

final class SQLiteHandle {
    let database: OpaquePointer
    init(path: String, create: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database."
            sqlite3_close(handle)
            throw BrowserError("SQLite: \(detail)")
        }
        database = handle
        sqlite3_busy_timeout(handle, Int32(BrowserPreferences.busyTimeout * 1000))
        sqlite3_exec(handle, "PRAGMA foreign_keys=ON", nil, nil, nil)
    }
    deinit { sqlite3_close(database) }

    func query(_ sql: String, parameters: [SQLValue] = [], limit: Int, visit: (([SQLValue]) throws -> Void)? = nil) throws -> QueryResult {
        try sql.withCString { start in
            var current: UnsafePointer<CChar>? = start
            var result = QueryResult()
            while let pointer = current, pointer.pointee != 0 {
                var statement: OpaquePointer?
                let prepare = sqlite3_prepare_v2(database, pointer, -1, &statement, &current)
                guard prepare == SQLITE_OK else { throw BrowserError("SQLite: \(String(cString: sqlite3_errmsg(database)))") }
                guard let statement else { continue }
                defer { sqlite3_finalize(statement) }
                if let tail = current, tail.pointee != 0,
                   !SQLDocument.statements(in: String(cString: tail), driver: .sqlite).isEmpty {
                    throw BrowserError("Expected one SQL statement. Use Run Script for multiple statements.")
                }
                if !parameters.isEmpty { try bind(parameters, to: statement) }
                let count = sqlite3_column_count(statement)
                result = QueryResult(columns: (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) })
                let changesBefore = sqlite3_total_changes64(database)
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    if result.rows.count < limit {
                        let values: [SQLValue] = (0..<count).map { i in
                            switch sqlite3_column_type(statement, i) {
                            case SQLITE_NULL: return .null
                            case SQLITE_INTEGER: return .integer(String(sqlite3_column_int64(statement, i)))
                            case SQLITE_FLOAT: return .number(String(sqlite3_column_double(statement, i)))
                            case SQLITE_BLOB:
                                let size = Int(sqlite3_column_bytes(statement, i))
                                return .blob(sqlite3_column_blob(statement, i).map { Data(bytes: $0, count: size) } ?? Data())
                            default:
                                let bytes = sqlite3_column_text(statement, i)!
                                return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, i))), as: UTF8.self))
                            }
                        }
                        if let visit { try visit(values) } else { result.rows.append(values) }
                    } else { result.truncated = true }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else { throw BrowserError("SQLite: \(String(cString: sqlite3_errmsg(database)))") }
                // changes64 retains the preceding DML count across DDL. Use the
                // total only to detect a write, not to count trigger side effects.
                if sqlite3_stmt_readonly(statement) == 0, sqlite3_total_changes64(database) != changesBefore {
                    result.affectedRows = sqlite3_changes64(database)
                }
            }
            return result
        }
    }
}

actor DatabaseSession {
    private var maria: MariaHandle?
    private var sqlite: SQLiteHandle?
    private var mariaEndpoint: (ConnectionProfile, String)?
    private var mariaDatabase = ""
    private var changedDatabase: String?
    private var tunnel: SSHTunnel?

    func open(_ profile: ConnectionProfile, password: String, sshPassword: String = "") throws -> String {
        close()
        do {
            switch profile.driver {
            case .mariaDB:
                var endpoint = profile
                if let settings = profile.ssh {
                    let tunnel = try SSHTunnel()
                    try tunnel.start(profile: profile, settings: settings, secret: sshPassword)
                    self.tunnel = tunnel
                    endpoint.usesSocket = true; endpoint.socketPath = tunnel.socket
                }
                let handle = try MariaHandle()
                try handle.open(endpoint, password: password)
                maria = handle
                mariaEndpoint = (endpoint, password)
                let name = try query("SELECT DATABASE()").rows.first?.first
                mariaDatabase = name == .null ? "" : name?.display ?? ""
                return mariaDatabase
            case .sqlite:
                sqlite = try SQLiteHandle(path: profile.filePath)
                _ = try query("PRAGMA schema_version")
                return URL(filePath: profile.filePath).lastPathComponent
            }
        } catch { close(); throw error }
    }

    static func createSQLite(at path: String) throws {
        let fd = Darwin.open(path, O_CREAT | O_EXCL | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw BrowserError("Could not create the new file: " + String(cString: strerror(errno))) }
        defer { Darwin.close(fd) }
        do {
            let handle = try SQLiteHandle(path: path)
            _ = try handle.query("PRAGMA user_version=0", limit: 0)
        } catch {
            var created = stat(), current = stat()
            if fstat(fd, &created) == 0 && lstat(path, &current) == 0 && created.st_dev == current.st_dev && created.st_ino == current.st_ino { _ = unlink(path) }
            throw error
        }
    }

    func maintain(_ request: MaintenanceRequest, job: MaintenanceJob) throws -> String {
        guard !hasOpenTransaction else { throw BrowserError("Finish the current transaction first.") }
        try checkExportDestination(request.file)
        return try DatabaseMaintenance.perform(request, job: job, sqlite: sqlite, endpoint: mariaEndpoint)
    }

    func checkExportDestination(_ destination: URL) throws {
        guard let sqlite, let path = sqlite3_db_filename(sqlite.database, "main") else { return }
        let source = URL(filePath: String(cString: path)).resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        var origin = stat(), targetFile = stat()
        if stat(source, &origin) == 0, stat(target, &targetFile) == 0, origin.st_dev == targetFile.st_dev && origin.st_ino == targetFile.st_ino {
            throw BrowserError("The selected file is the active SQLite database.")
        }
        guard ![source, source + "-wal", source + "-shm", source + "-journal"].contains(target) else {
            throw BrowserError("Choose an export file outside the active database and its journal files.")
        }
    }

    var hasOpenTransaction: Bool {
        if let sqlite { return sqlite3_get_autocommit(sqlite.database) == 0 }
        if let maria { return maria.connection.pointee.server_status & UInt32(SERVER_STATUS_IN_TRANS) != 0 }
        return false
    }

    func close() {
        maria = nil; sqlite = nil; mariaEndpoint = nil; tunnel = nil
        mariaDatabase = ""; changedDatabase = nil
    }

    func selectDatabase(_ name: String) throws {
        guard let maria else { throw BrowserError("No MariaDB session is open.") }
        guard !hasOpenTransaction, changedDatabase == nil else { throw BrowserError("Finish the current transaction or database switch first.") }
        guard mysql_select_db(maria.connection, name) == 0 else { throw maria.failure() }
        mariaDatabase = name
    }

    func finishDatabaseChange(to name: String, accept: Bool) throws {
        guard changedDatabase == name, let maria else { throw BrowserError("The session changed before the database switch completed.") }
        defer { changedDatabase = nil }
        if accept { mariaDatabase = name; return }
        guard !mariaDatabase.isEmpty, mysql_select_db(maria.connection, mariaDatabase) == 0 else {
            close()
            throw BrowserError("The original database is unavailable. Reconnect before applying pending changes.", disconnected: true)
        }
        throw BrowserError("Finish pending changes, transactions, and running operations before switching databases.")
    }

    func runUserSQL(_ sql: String, on expectedDatabase: String, cancellation: QueryCancellation, limit: Int) throws -> (results: [QueryResult], changedDatabase: String?) {
        if let sqlite {
            // sqlite3_interrupt is specifically safe from another thread while
            // the retained connection is executing sqlite3_step.
            return ([try cancellation.perform(interrupt: { sqlite3_interrupt(sqlite.database) }) {
                try query(sql, limit: limit)
            }], nil)
        }
        if let maria, let (profile, password) = mariaEndpoint {
            guard changedDatabase == nil, expectedDatabase == mariaDatabase else {
                throw BrowserError("The active database changed. Review the query target before running it again.")
            }
            let inTransaction = hasOpenTransaction
            let threadID = mysql_thread_id(maria.connection)
            let resultSets = try cancellation.perform(interrupt: {
                var target = profile; target.database = ""
                let control = try MariaHandle()
                try control.open(target, password: password)
                _ = try control.query("KILL QUERY \(threadID)", limit: 0)
            }) { try userResultSets(sql, limit: limit) }
            let current: String
            var bytes: UnsafePointer<CChar>?, length = 0
            if mysql_session_track_get_first(maria.connection, SESSION_TRACK_SCHEMA, &bytes, &length) == 0 {
                current = String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
            } else {
                let token = sql.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0.isLetter }.uppercased()
                if ["SELECT", "SHOW", "DESCRIBE", "EXPLAIN", "INSERT", "UPDATE", "DELETE", "REPLACE"].contains(token) {
                    current = mariaDatabase
                } else {
                    // Older servers and sessions with tracking disabled may omit
                    // the schema from the protocol. Observe this thread from a
                    // second login so ROW_COUNT() and SHOW WARNINGS stay intact.
                    do {
                        var endpoint = profile; endpoint.database = ""
                        let observer = try MariaHandle()
                        try observer.open(endpoint, password: password)
                        let row = try observer.query("SELECT DB FROM information_schema.PROCESSLIST WHERE ID=" + String(threadID), limit: 1).rows.first
                        guard let value = row?.first else { throw BrowserError("The server did not expose the session database.") }
                        current = value == .null ? "" : value.display
                    } catch {
                        close()
                        throw BrowserError("The statement finished, but its database target could not be verified. Reconnect before continuing. " + error.localizedDescription, disconnected: true)
                    }
                }
            }
            if current != mariaDatabase {
                changedDatabase = current
                if inTransaction { try finishDatabaseChange(to: current, accept: false) }
            }
            return (resultSets, changedDatabase)
        }
        throw BrowserError("This workspace is disconnected.", disconnected: true)
    }

    private func userResultSets(_ sql: String, limit: Int) throws -> [QueryResult] {
        var sets: [QueryResult] = []
        let status = try read(sql, parameters: [], limit: limit, visit: nil, receiveResult: { sets.append($0) })
        return sets.isEmpty ? [status] : sets
    }

    func query(_ sql: String, parameters: [SQLValue] = [], limit: Int = 1000) throws -> QueryResult {
        try read(sql, parameters: parameters, limit: limit, visit: nil)
    }

    func read(_ sql: String, parameters: [SQLValue], limit: Int, visit: (([SQLValue]) throws -> Void)?, receiveResult: ((QueryResult) -> Void)? = nil) throws -> QueryResult {
        guard changedDatabase == nil else { throw BrowserError("The database is changing. Wait for the catalog to reload.") }
        if let maria {
            do {
                if !parameters.isEmpty { return try maria.preparedQuery(sql, parameters: parameters, limit: limit, visit: visit) }
                return try maria.query(sql, limit: limit, visit: visit, receiveResult: receiveResult)
            } catch let error as BrowserError {
                if error.disconnected { close() }
                throw error
            }
        }
        if let sqlite { return try sqlite.query(sql, parameters: parameters, limit: limit, visit: visit) }
        throw BrowserError("This workspace is disconnected.", disconnected: true)
    }

    func objects() throws -> [DatabaseObject] {
        if maria != nil {
            let rows = try query("SHOW FULL TABLES", limit: .max).rows
            return rows.map { DatabaseObject(name: $0[0].display, kind: $0[1].display == "VIEW" ? .view : .table) }
        }
        return try query("SELECT name, type FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name", limit: .max).rows.map {
            DatabaseObject(name: $0[0].display, kind: $0[1].display == "view" ? .view : .table)
        }
    }

    static func identifier(_ name: String) -> String { "\u{60}" + name.replacingOccurrences(of: "\u{60}", with: "\u{60}\u{60}") + "\u{60}" }
}
