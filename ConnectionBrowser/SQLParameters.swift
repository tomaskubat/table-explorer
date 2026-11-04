import CMariaDB
import Foundation
import SQLite3

extension MariaHandle {
    func preparedQuery(_ sql: String, parameters: [SQLValue], limit: Int) throws -> QueryResult {
        guard let statement = mysql_stmt_init(connection) else { throw failure() }
        defer { mysql_stmt_close(statement) }
        func statementError() -> BrowserError { BrowserError.maria(mysql_stmt_errno(statement), String(cString: mysql_stmt_error(statement))) }
        guard mysql_stmt_prepare(statement, sql, UInt(sql.utf8.count)) == 0 else { throw statementError() }
        guard mysql_stmt_param_count(statement) == parameters.count else { throw BrowserError("The number of SQL parameters does not match the statement.") }

        let buffers: [NSData] = parameters.map {
            switch $0 {
            case .blob(let bytes): return bytes as NSData
            case .null: return NSData()
            default: return Data($0.display.utf8) as NSData
            }
        }
        var inputs = parameters.enumerated().map { index, value in
            var bind = MYSQL_BIND()
            switch value {
            case .null: bind.buffer_type = MYSQL_TYPE_NULL
            case .blob: bind.buffer_type = MYSQL_TYPE_BLOB
            default: bind.buffer_type = MYSQL_TYPE_STRING
            }
            bind.buffer = UnsafeMutableRawPointer(mutating: buffers[index].bytes)
            bind.buffer_length = UInt(buffers[index].length)
            return bind
        }
        try withExtendedLifetime(buffers) {
            guard mysql_stmt_bind_param(statement, &inputs) == 0, mysql_stmt_execute(statement) == 0 else { throw statementError() }
        }
        guard let metadata = mysql_stmt_result_metadata(statement) else {
            if mysql_stmt_field_count(statement) > 0 { throw statementError() }
            return QueryResult(affectedRows: Int64(bitPattern: mysql_stmt_affected_rows(statement)))
        }
        defer { mysql_free_result(metadata) }
        let count = Int(mysql_num_fields(metadata))
        let fields = mysql_fetch_fields(metadata)!
        var result = QueryResult(columns: (0..<count).map { String(cString: fields[$0].name) })
        // First ask for exact lengths. Fetch each non-NULL cell into an owned
        // buffer so a large BLOB never becomes a silently truncated string.
        let lengths = UnsafeMutableBufferPointer<UInt>.allocate(capacity: count)
        let nulls = UnsafeMutableBufferPointer<my_bool>.allocate(capacity: count)
        defer { lengths.deallocate(); nulls.deallocate() }
        var outputs = (0..<count).map { i in
            var bind = MYSQL_BIND()
            bind.buffer_type = MYSQL_TYPE_STRING
            bind.length = lengths.baseAddress! + i
            bind.is_null = nulls.baseAddress! + i
            return bind
        }
        guard mysql_stmt_bind_result(statement, &outputs) == 0 else { throw statementError() }
        while true {
            let status = mysql_stmt_fetch(statement)
            if status == MYSQL_NO_DATA { break }
            guard status == 0 || status == MYSQL_DATA_TRUNCATED else { throw statementError() }
            guard result.rows.count < limit else { result.truncated = true; continue }
            var row: [SQLValue] = []
            for i in 0..<count {
                if nulls[i] != 0 { row.append(.null); continue }
                var bytes = Data(count: Int(lengths[i]))
                if !bytes.isEmpty {
                    try bytes.withUnsafeMutableBytes { buffer in
                        var column = outputs[i]
                        column.buffer = buffer.baseAddress
                        column.buffer_length = UInt(buffer.count)
                        guard mysql_stmt_fetch_column(statement, &column, UInt32(i), 0) == 0 else { throw statementError() }
                    }
                }
                row.append(Self.value(bytes, field: fields[i]))
            }
            result.rows.append(row)
        }
        return result
    }
}

extension SQLiteHandle {
    func bind(_ parameters: [SQLValue], to statement: OpaquePointer) throws {
        guard sqlite3_bind_parameter_count(statement) == parameters.count else { throw BrowserError("The number of SQL parameters does not match the statement.") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            let i = Int32(index + 1)
            let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, i)
            case .integer(let text):
                guard let number = Int64(text) else { throw BrowserError("Invalid integer \(text).") }
                status = sqlite3_bind_int64(statement, i, number)
            case .number(let text):
                guard let number = Double(text) else { throw BrowserError("Invalid number \(text).") }
                status = sqlite3_bind_double(statement, i, number)
            case .text(let text):
                status = sqlite3_bind_text(statement, i, text, Int32(text.utf8.count), transient)
            case .blob(let data):
                if data.isEmpty { status = sqlite3_bind_zeroblob(statement, i, 0) }
                else { status = data.withUnsafeBytes { sqlite3_bind_blob64(statement, i, $0.baseAddress, UInt64($0.count), transient) } }
            }
            guard status == SQLITE_OK else { throw BrowserError("Could not bind SQL parameter \(i).") }
        }
    }
}
