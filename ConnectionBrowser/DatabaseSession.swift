import CMariaDB
import Foundation
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
    enum Kind: String, Sendable { case table = "Table", view = "View", procedure = "Procedure", function = "Function" }
    let name: String
    let kind: Kind
    var id: Self { self }
}

private final class MariaHandle {
    let connection: UnsafeMutablePointer<MYSQL>
    init() throws {
        guard let handle = mysql_init(nil) else { throw BrowserError("Could not allocate a MariaDB connection.") }
        connection = handle
    }
    deinit { mysql_close(connection) }

    func open(_ profile: ConnectionProfile, password: String) throws {
        var timeout: UInt32 = 5
        var mode = profile.usesSocket ? MYSQL_PROTOCOL_SOCKET : MYSQL_PROTOCOL_TCP
        mysql_options(connection, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)
        mysql_options(connection, MYSQL_OPT_PROTOCOL, &mode)
        mysql_options(connection, MYSQL_SET_CHARSET_NAME, "utf8mb4")
        var localInfile: UInt32 = 0
        mysql_options(connection, MYSQL_OPT_LOCAL_INFILE, &localInfile)
        var tls: my_bool = profile.verifyTLS ? 1 : 0
        mysql_options(connection, MYSQL_OPT_SSL_ENFORCE, &tls)
        mysql_options(connection, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &tls)
        if profile.verifyTLS && !profile.caPath.isEmpty { mysql_options(connection, MYSQL_OPT_SSL_CA, profile.caPath) }
        guard profile.usesSocket || UInt16(profile.port).map({ $0 > 0 }) == true else { throw BrowserError("Enter a port between 1 and 65535.") }
        let server = profile.usesSocket ? "localhost" : profile.host
        let connected = mysql_real_connect(connection, server, profile.user, password,
            profile.database.isEmpty ? nil : profile.database, UInt32(profile.port) ?? 0,
            profile.usesSocket ? profile.socketPath : nil, 0)
        guard connected != nil else { throw failure() }
        if profile.verifyTLS && mysql_get_ssl_cipher(connection) == nil { throw BrowserError("The server did not establish a TLS connection.") }
    }

    func failure() -> BrowserError {
        BrowserError("MariaDB \(mysql_errno(connection)): \(String(cString: mysql_error(connection)))")
    }

    func query(_ sql: String, limit: Int) throws -> QueryResult {
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
                    result.rows.append(values)
                }
                if mysql_errno(connection) != 0 { throw failure() }
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

private final class SQLiteHandle {
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
        sqlite3_busy_timeout(handle, 3000)
        sqlite3_exec(handle, "PRAGMA foreign_keys=ON", nil, nil, nil)
    }
    deinit { sqlite3_close(database) }

    func query(_ sql: String, limit: Int) throws -> QueryResult {
        try sql.withCString { start in
            var current: UnsafePointer<CChar>? = start
            var result = QueryResult()
            while let pointer = current, pointer.pointee != 0 {
                var statement: OpaquePointer?
                let prepare = sqlite3_prepare_v2(database, pointer, -1, &statement, &current)
                guard prepare == SQLITE_OK else { throw BrowserError("SQLite: \(String(cString: sqlite3_errmsg(database)))") }
                guard let statement else { continue }
                defer { sqlite3_finalize(statement) }
                let count = sqlite3_column_count(statement)
                result = QueryResult(columns: (0..<count).map { String(cString: sqlite3_column_name(statement, $0)) })
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    if result.rows.count < limit {
                        result.rows.append((0..<count).map { i in
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
                        })
                    } else { result.truncated = true }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else { throw BrowserError("SQLite: \(String(cString: sqlite3_errmsg(database)))") }
                if sqlite3_stmt_readonly(statement) == 0 { result.affectedRows = sqlite3_changes64(database) }
            }
            return result
        }
    }
}

actor DatabaseSession {
    private var maria: MariaHandle?
    private var sqlite: SQLiteHandle?

    func open(_ profile: ConnectionProfile, password: String) throws -> String {
        close()
        do {
            switch profile.driver {
            case .mariaDB:
                let handle = try MariaHandle()
                try handle.open(profile, password: password)
                maria = handle
                let name = try query("SELECT DATABASE()").rows.first?.first
                return name == .null ? "" : name?.display ?? ""
            case .sqlite:
                sqlite = try SQLiteHandle(path: profile.filePath)
                _ = try query("PRAGMA schema_version")
                return URL(filePath: profile.filePath).lastPathComponent
            }
        } catch { close(); throw error }
    }

    func close() { maria = nil; sqlite = nil }

    func query(_ sql: String, limit: Int = 1000) throws -> QueryResult {
        if let maria { return try maria.query(sql, limit: limit) }
        if let sqlite { return try sqlite.query(sql, limit: limit) }
        throw BrowserError("This workspace is disconnected.")
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
