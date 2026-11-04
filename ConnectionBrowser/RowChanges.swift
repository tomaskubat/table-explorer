import Foundation

struct RowChange: Identifiable, Sendable {
    let id: UUID
    let original: [String: SQLValue]?
    var changes: [String: SQLValue]
    var deleted = false
    init(id: UUID = UUID(), original: [String: SQLValue]?, changes: [String: SQLValue] = [:]) {
        self.id = id; self.original = original; self.changes = changes
    }
}

struct RowStatement: Sendable {
    let sql: String
    let bindings: [SQLValue]
    let preview: String
}

enum ChangeSQL {
    static func statement(_ change: RowChange, object: DatabaseObject, schema: ObjectSchema, driver: DatabaseDriver) throws -> RowStatement {
        let name = DatabaseSession.identifier(object.name)
        let fields = schema.columns.filter { !($0.generated) && change.changes[$0.name] != nil }.map(\.name)
        let values = fields.map { change.changes[$0]! }
        guard object.kind == .table, schema.transactional else { throw BrowserError("This object does not support transactional row editing.") }

        let form: ([String], [String]) -> String
        var keys: [SQLValue] = []
        if let original = change.original {
            let keyNames = schema.key.map(\.name)
            keys = keyNames.compactMap { original[$0] }
            guard !keys.isEmpty, keys.count == keyNames.count, !keys.contains(.null) else { throw BrowserError("A non-NULL primary key is required to identify this row.") }
            guard change.deleted || !fields.isEmpty else { throw BrowserError("There are no changed fields.") }
            form = { replacements, identity in
                let predicate = zip(keyNames, identity).map { DatabaseSession.identifier($0) + " = " + $1 }.joined(separator: " AND ")
                if change.deleted { return "DELETE FROM \(name) WHERE \(predicate)" }
                let updates = zip(fields, replacements).map { DatabaseSession.identifier($0) + " = " + $1 }.joined(separator: ", ")
                return "UPDATE \(name) SET \(updates) WHERE \(predicate)"
            }
        } else {
            form = { replacements, _ in
                if fields.isEmpty { return driver == .sqlite ? "INSERT INTO \(name) DEFAULT VALUES" : "INSERT INTO \(name) () VALUES ()" }
                return "INSERT INTO \(name) (" + fields.map(DatabaseSession.identifier).joined(separator: ", ") + ") VALUES (" + replacements.joined(separator: ", ") + ")"
            }
        }
        let boundValues = change.deleted ? [] : values
        return RowStatement(sql: form(boundValues.map { _ in "?" }, keys.map { _ in "?" }), bindings: boundValues + keys,
                            preview: form(boundValues.map { literal($0, driver: driver) }, keys.map { literal($0, driver: driver) }) + ";")
    }

    static func literal(_ value: SQLValue, driver: DatabaseDriver) -> String {
        switch value {
        case .null: return "NULL"
        case .integer(let text), .number(let text): return text
        case .blob(let bytes): return "X'" + bytes.map { String(format: "%02X", $0) }.joined() + "'"
        case .text(let text):
            if text.contains("\0") || (driver == .mariaDB && text.contains("\\")) {
                let hex = Data(text.utf8).map { String(format: "%02X", $0) }.joined()
                return driver == .sqlite ? "CAST(X'\(hex)' AS TEXT)" : "CONVERT(X'\(hex)' USING utf8mb4)"
            }
            return "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }
}

extension DatabaseSession {
    func commit(_ changes: [RowChange], object: DatabaseObject, driver: DatabaseDriver) throws {
        let schema = try schema(of: object, driver: driver)
        let statements = try changes.map { try ChangeSQL.statement($0, object: object, schema: schema, driver: driver) }
        guard !hasOpenTransaction else { throw BrowserError("Finish the current SQL transaction before committing row changes.") }
        _ = try query(driver == .sqlite ? "BEGIN IMMEDIATE" : "START TRANSACTION")
        do {
            for (change, statement) in zip(changes, statements) {
                if let original = change.original {
                    let predicate = schema.key.map { Self.identifier($0.name) + " = ?" }.joined(separator: " AND ")
                    var sql = "SELECT * FROM \(Self.identifier(object.name)) WHERE \(predicate)"
                    if driver == .mariaDB { sql += " FOR UPDATE" }
                    let existing = try query(sql, parameters: schema.key.map { original[$0.name]! })
                    guard existing.rows.count == 1,
                          Dictionary(uniqueKeysWithValues: zip(existing.columns, existing.rows[0])) == original else {
                        throw BrowserError("Conflict: the row was changed or deleted by another session. Your draft has been kept.")
                    }
                }
                _ = try query(statement.sql, parameters: statement.bindings)
            }
            _ = try query("COMMIT")
        } catch {
            _ = try? query("ROLLBACK")
            throw error
        }
    }
}
