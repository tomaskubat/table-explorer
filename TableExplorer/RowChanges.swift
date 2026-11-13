import Foundation

struct RowChange: Identifiable, Sendable {
    let id: UUID
    let original: [String: SQLValue]?
    var changes: [String: SQLValue]
    var deleted = false
    var defaults: Set<String> = []
    init(id: UUID = UUID(), original: [String: SQLValue]?, changes: [String: SQLValue] = [:]) {
        self.id = id; self.original = original; self.changes = changes
    }
}

struct RowStatement: Sendable {
    let sql: String
    let bindings: [SQLValue]
    let preview: String
    let formattedPreview: String
}

enum ChangeSQL {
    static func statement(_ change: RowChange, object: DatabaseObject, schema: ObjectSchema, driver: DatabaseDriver) throws -> RowStatement {
        let name = DatabaseSession.identifier(object.name)
        let affected = schema.columns.filter { !$0.generated && (change.changes[$0.name] != nil || (change.original != nil && change.defaults.contains($0.name))) }
        let fields = affected.map(\.name)
        let values = affected.compactMap { change.defaults.contains($0.name) ? nil : change.changes[$0.name] }
        func replacements(literals: Bool) throws -> [String] {
            try affected.map { column in
                if change.defaults.contains(column.name) {
                    guard column.defaultSQL != nil || column.nullable else { throw BrowserError("\(column.name) has no default value.") }
                    return driver == .mariaDB ? "DEFAULT" : "(" + (column.defaultSQL ?? "NULL") + ")"
                }
                return literals ? literal(change.changes[column.name]!, driver: driver) : "?"
            }
        }
        guard object.kind == .table, schema.transactional else { throw BrowserError("This object does not support transactional row editing.") }

        let form: ([String], [String], Bool) -> String
        var keys: [SQLValue] = []
        if let original = change.original {
            let keyNames = schema.key.map(\.name)
            keys = keyNames.compactMap { original[$0] }
            guard !keys.isEmpty, keys.count == keyNames.count, !keys.contains(.null) else { throw BrowserError("A non-NULL primary key is required to identify this row.") }
            guard change.deleted || !fields.isEmpty else { throw BrowserError("There are no changed fields.") }
            form = { replacements, identity, formatted in
                let line = formatted ? "\n" : " ", indent = formatted ? "  " : ""
                let predicate = zip(keyNames, identity).map { DatabaseSession.identifier($0) + " = " + $1 }.joined(separator: formatted ? "\n  AND " : " AND ")
                if change.deleted { return "DELETE FROM \(name)\(line)WHERE\(line)\(indent)\(predicate)" }
                let updates = zip(fields, replacements).map { DatabaseSession.identifier($0) + " = " + $1 }.joined(separator: formatted ? ",\n  " : ", ")
                return "UPDATE \(name)\(line)SET\(line)\(indent)\(updates)\(line)WHERE\(line)\(indent)\(predicate)"
            }
        } else {
            form = { replacements, _, formatted in
                let line = formatted ? "\n" : " "
                if fields.isEmpty { return driver == .sqlite ? "INSERT INTO \(name)\(line)DEFAULT VALUES" : "INSERT INTO \(name) ()\(line)VALUES ()" }
                if formatted {
                    return "INSERT INTO \(name) (\n  " + fields.map(DatabaseSession.identifier).joined(separator: ",\n  ") + "\n)\nVALUES (\n  " + replacements.joined(separator: ",\n  ") + "\n)"
                }
                return "INSERT INTO \(name) (" + fields.map(DatabaseSession.identifier).joined(separator: ", ") + ") VALUES (" + replacements.joined(separator: ", ") + ")"
            }
        }
        let boundValues = change.deleted ? [] : values
        let literals = try change.deleted ? [] : replacements(literals: true)
        let identity = keys.map { literal($0, driver: driver) }
        return try RowStatement(sql: form(change.deleted ? [] : replacements(literals: false), keys.map { _ in "?" }, false), bindings: boundValues + keys,
                                preview: form(literals, identity, false) + ";", formattedPreview: form(literals, identity, true) + ";")
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
    @discardableResult func commit(_ changes: [RowChange], object: DatabaseObject, driver: DatabaseDriver) throws -> [String] {
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
            return statements.map(\.preview)
        } catch {
            _ = try? query("ROLLBACK")
            throw error
        }
    }
}
