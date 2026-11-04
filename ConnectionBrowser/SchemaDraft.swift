import Foundation

struct DraftColumn: Identifiable {
    var id = UUID()
    var name = ""
    var type = "TEXT"
    var nullable = true
    var defaultExpression = ""
}

struct DraftIndex: Identifiable {
    var id = UUID()
    var name = ""
    var columns = ""
    var unique = false
}

struct DraftForeignKey: Identifiable {
    var id = UUID()
    var columns = ""
    var table = ""
    var referenced = ""
}

struct SchemaDraft: Identifiable {
    let id = UUID()
    let kind: DatabaseObject.Kind
    var name = ""
    var columns = [DraftColumn(name: "id", type: "INTEGER", nullable: false)]
    var primaryKey = "id"
    var indexes: [DraftIndex] = []
    var foreignKeys: [DraftForeignKey] = []
    var select = "SELECT "
    var parameters = ""
    var returnType = "INTEGER"
    var routineBody = ""
    var isRoutine: Bool { kind == .procedure || kind == .function }

    func ddl(_ driver: DatabaseDriver) throws -> [String] {
        let quote = DatabaseSession.identifier
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.contains("\0") else { throw BrowserError("Enter an object name.") }
        if isRoutine {
            guard driver == .mariaDB else { throw BrowserError("SQLite does not support stored routines.") }
            let body = routineBody.trimmingCharacters(in: .whitespacesAndNewlines)
            let returns = returnType.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, !body.contains("\0"), !parameters.contains("\0"),
                  !parameters.contains(";"), !returns.contains(";"), kind != .function || !returns.isEmpty else {
                throw BrowserError("Enter a routine body and valid parameter and return types.")
            }
            if body.range(of: #"(?im)^\s*DELIMITER\b"#, options: .regularExpression) != nil {
                throw BrowserError("Enter the routine body directly, without a client DELIMITER directive.")
            }
            let header = "CREATE " + kind.rawValue.uppercased() + " " + quote(name) + "(" + parameters + ")"
            return [header + (kind == .function ? " RETURNS " + returns : "") + " SQL SECURITY INVOKER\n" + body]
        }
        if kind == .view {
            let queries = SQLDocument.statements(in: select, driver: driver)
            guard queries.count == 1 else { throw BrowserError("A view requires a single SELECT statement.") }
            var body = queries[0].sql
            if body.last == ";" { body.removeLast() }
            guard ["SELECT", "WITH"].contains(body.uppercased().prefix { $0.isLetter }) else { throw BrowserError("Start the view definition with SELECT or WITH.") }
            return ["CREATE VIEW \(quote(name)) AS\n\(body)"]
        }
        let names = columns.map(\.name)
        guard !names.isEmpty, names.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.contains("\0") }),
              Set(names.map { $0.lowercased() }).count == names.count else { throw BrowserError("Give every column a unique name.") }
        var definitions: [String] = []
        for column in columns {
            let type = column.type.trimmingCharacters(in: .whitespaces)
            guard !type.isEmpty else { throw BrowserError("Enter a type for \(column.name).") }
            var definition = quote(column.name) + " " + type
            if !column.nullable { definition += " NOT NULL" }
            if !column.defaultExpression.isEmpty { definition += " DEFAULT " + column.defaultExpression }
            definitions.append(definition)
        }
        func list(_ text: String, checkLocal: Bool = true) throws -> [String] {
            let parts = text.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.allSatisfy({ !$0.isEmpty && (!checkLocal || names.contains($0)) }), Set(parts).count == parts.count else {
                throw BrowserError("List each column once, in key order. Check the names in “\(text)”.")
            }
            return parts
        }
        if !primaryKey.trimmingCharacters(in: .whitespaces).isEmpty { definitions.append("PRIMARY KEY (" + (try list(primaryKey)).map(quote).joined(separator: ", ") + ")") }
        for key in foreignKeys {
            let local = try list(key.columns), remote = try list(key.referenced, checkLocal: false)
            guard local.count == remote.count, !key.table.isEmpty else { throw BrowserError("Each foreign key needs a table and matching lists of local and referenced columns.") }
            definitions.append("FOREIGN KEY (" + local.map(quote).joined(separator: ", ") + ") REFERENCES " + quote(key.table) + " (" + remote.map(quote).joined(separator: ", ") + ")")
        }
        var extra: [String] = []
        for index in indexes {
            guard !index.name.isEmpty else { throw BrowserError("Enter a name for each index.") }
            let fields = "(" + (try list(index.columns)).map(quote).joined(separator: ", ") + ")"
            let prefix = (index.unique ? "UNIQUE " : "") + "INDEX " + quote(index.name)
            if driver == .mariaDB { definitions.append(prefix + " " + fields) }
            else { extra.append("CREATE " + prefix + " ON " + quote(name) + " " + fields) }
        }
        let statements = ["CREATE TABLE " + quote(name) + " (\n  " + definitions.joined(separator: ",\n  ") + "\n)"] + extra
        guard statements.allSatisfy({ SQLDocument.statements(in: $0, driver: driver).count == 1 }) else {
            throw BrowserError("Column types and defaults cannot contain additional SQL statements.")
        }
        return statements
    }
}

extension DatabaseSession {
    func applySchema(_ statements: [String], driver: DatabaseDriver) throws {
        guard !hasOpenTransaction else { throw BrowserError("Finish the current transaction before changing the schema.") }
        if driver == .mariaDB {
            guard statements.count == 1 else { throw BrowserError("MariaDB DDL may implicitly commit. Apply one schema operation at a time.") }
            _ = try query(statements[0]); return
        }
        _ = try query("BEGIN IMMEDIATE")
        do { for statement in statements { _ = try query(statement) }; _ = try query("COMMIT") }
        catch { _ = try? query("ROLLBACK"); throw error }
    }

    func routines() throws -> [DatabaseObject] {
        let result = try query("SELECT ROUTINE_NAME,ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=DATABASE() ORDER BY ROUTINE_NAME", limit: .max)
        return result.rows.map { DatabaseObject(name: $0[0].display, kind: $0[1].display == "FUNCTION" ? .function : .procedure) }
    }
}
