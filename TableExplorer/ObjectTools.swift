import Foundation

enum ObjectOperation: String, Identifiable {
    case clone = "Clone", empty = "Empty Table", drop = "Delete Object", rename = "Rename", addColumn = "Add Column", addIndex = "Add Index"
    var id: Self { self }
    var destructive: Bool { self == .empty || self == .drop }
}

struct ObjectOperationTarget: Identifiable {
    let id = UUID()
    let object: DatabaseObject
    let operation: ObjectOperation
}

extension DatabaseSession {
    func overview(driver: DatabaseDriver) throws -> QueryResult {
        if driver == .sqlite { return try query("SELECT name,type,tbl_name AS owner,rootpage,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY type,name", limit: .max) }
        return try query("""
            SELECT TABLE_NAME,TABLE_SCHEMA,TABLE_TYPE,TABLE_COLLATION,ENGINE,TABLE_ROWS AS estimated_rows,
                   DATA_LENGTH,INDEX_LENGTH,DATA_LENGTH+INDEX_LENGTH AS total_bytes,TABLE_COMMENT
            FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() ORDER BY TABLE_NAME
            """, limit: .max)
    }

    func planObjectOperation(_ target: ObjectOperationTarget, driver: DatabaseDriver, name: String, definition: String,
                             includeData: Bool, unique: Bool) throws -> [String] {
        let object = target.object, source = Self.identifier(object.name), destination = Self.identifier(name)
        if [.clone, .rename, .addColumn, .addIndex].contains(target.operation), name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BrowserError("Enter a name.")
        }
        switch target.operation {
        case .drop: return ["DROP \(object.kind.rawValue.uppercased()) \(source)"]
        case .empty:
            guard object.kind == .table else { throw BrowserError("Choose a table.") }
            return [driver == .mariaDB ? "TRUNCATE TABLE \(source)" : "DELETE FROM \(source)"]
        case .rename:
            guard object.kind == .table || (driver == .mariaDB && object.kind == .view) else { throw BrowserError("This object cannot be renamed by its driver.") }
            return [driver == .sqlite ? "ALTER TABLE \(source) RENAME TO \(destination)" : "RENAME TABLE \(source) TO \(destination)"]
        case .addColumn:
            let sql = "ALTER TABLE \(source) ADD COLUMN \(destination) " + definition
            guard object.kind == .table, !definition.trimmingCharacters(in: .whitespaces).isEmpty,
                  SQLDocument.statements(in: sql, driver: driver).count == 1 else { throw BrowserError("Enter a single column definition.") }
            return [sql]
        case .addIndex:
            let columns = definition.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let schema = try schema(of: object, driver: driver)
            guard object.kind == .table, !columns.isEmpty, Set(columns).count == columns.count,
                  columns.allSatisfy({ name in schema.columns.contains { $0.name == name } }) else { throw BrowserError("Enter the table's column names in index order.") }
            return ["CREATE " + (unique ? "UNIQUE " : "") + "INDEX \(destination) ON \(source) (" + columns.map(Self.identifier).joined(separator: ", ") + ")"]
        case .clone:
            guard object.kind == .table || object.kind == .view, name != object.name else { throw BrowserError("Choose a distinct destination name for a table or view.") }
            var commands: [String] = []
            if driver == .sqlite { commands = try sqliteClone(object, newName: name) }
            else if object.kind == .view {
                let result = try query("SELECT VIEW_DEFINITION FROM information_schema.VIEWS WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?", parameters: [.text(object.name)])
                guard let definition = result.rows.first?.first, definition != .null else { throw BrowserError("The account cannot read the view definition.") }
                commands = ["CREATE SQL SECURITY INVOKER VIEW \(destination) AS " + definition.display]
            } else {
                commands = ["CREATE TABLE \(destination) LIKE \(source)"]
                commands += try mariaForeignKeys(object, newName: name)
            }
            if includeData && object.kind == .table {
                let fields = try schema(of: object, driver: driver).columns.filter { !$0.generated }.map { Self.identifier($0.name) }.joined(separator: ", ")
                commands.append("INSERT INTO \(destination) (\(fields)) SELECT \(fields) FROM \(source)")
            }
            return commands
        }
    }

    private func sqliteClone(_ object: DatabaseObject, newName: String) throws -> [String] {
        let source = Self.identifier(object.name), destination = Self.identifier(newName)
        let result = try query("SELECT type,name,sql FROM sqlite_schema WHERE tbl_name=? AND sql IS NOT NULL AND type IN ('table','view','index') ORDER BY CASE type WHEN 'index' THEN 1 ELSE 0 END", parameters: [.text(object.name)], limit: .max)
        guard let first = result.rows.first else { throw BrowserError("The source definition is unavailable.") }
        if object.kind == .view {
            return [try renamedDefinition(first[2].display, kind: "VIEW", name: newName)]
        }
        guard !first[2].display.uppercased().hasPrefix("CREATE VIRTUAL TABLE") else { throw BrowserError("Virtual tables require a module-specific clone operation.") }
        // Let SQLite itself rewrite self-references and expressions when
        // renaming the schema. The working copy contains no live rows.
        let scratch = try SQLiteHandle(path: ":memory:", create: true)
        for row in result.rows { _ = try scratch.query(row[2].display, limit: 0) }
        _ = try scratch.query("ALTER TABLE \(source) RENAME TO \(destination)", limit: 0)
        let definitions = try scratch.query("SELECT type,name,sql FROM sqlite_schema WHERE tbl_name=? AND sql IS NOT NULL ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END", parameters: [.text(newName)], limit: .max)
        return try definitions.rows.map { row in
            if row[0].display == "index" { return try renamedDefinition(row[2].display, kind: "INDEX", name: newName + "_" + row[1].display) }
            return row[2].display
        }
    }

    private func renamedDefinition(_ ddl: String, kind: String, name: String) throws -> String {
        let token = #"(?:\"(?:[^\"]|\"\")*\"|\x60(?:[^\x60]|\x60\x60)*\x60|\[[^\]]*\]|'(?:[^']|'')*'|[^\s(.]+)"#
        let pattern = #"^\s*CREATE\s+(?:UNIQUE\s+)?"# + kind + #"\s+(?:IF\s+NOT\s+EXISTS\s+)?("# + token + ")"
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let source = ddl as NSString
        guard let match = regex.firstMatch(in: ddl, range: NSRange(location: 0, length: source.length)) else {
            throw BrowserError("Cannot safely rename this \(kind.lowercased()) definition.")
        }
        return source.replacingCharacters(in: match.range(at: 1), with: Self.identifier(name))
    }

    private func mariaForeignKeys(_ object: DatabaseObject, newName: String) throws -> [String] {
        let result = try query("""
            SELECT k.CONSTRAINT_NAME,k.COLUMN_NAME,k.REFERENCED_TABLE_SCHEMA,k.REFERENCED_TABLE_NAME,
                   k.REFERENCED_COLUMN_NAME,r.UPDATE_RULE,r.DELETE_RULE,DATABASE()
            FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r
            ON r.CONSTRAINT_SCHEMA=k.TABLE_SCHEMA AND r.TABLE_NAME=k.TABLE_NAME AND r.CONSTRAINT_NAME=k.CONSTRAINT_NAME
            WHERE k.TABLE_SCHEMA=DATABASE() AND k.TABLE_NAME=? ORDER BY k.CONSTRAINT_NAME,k.ORDINAL_POSITION
            """, parameters: [.text(object.name)], limit: .max)
        return Dictionary(grouping: result.rows, by: { $0[0].display }).keys.sorted().map { key in
            let rows = result.rows.filter { $0[0].display == key }, first = rows[0]
            let referenced = first[2] == first[7] && first[3].display == object.name ? newName : first[3].display
            return "ALTER TABLE " + Self.identifier(newName) + " ADD FOREIGN KEY (" +
                rows.map { Self.identifier($0[1].display) }.joined(separator: ", ") + ") REFERENCES " +
                Self.identifier(first[2].display) + "." + Self.identifier(referenced) + " (" +
                rows.map { Self.identifier($0[4].display) }.joined(separator: ", ") + ") ON UPDATE " + first[5].display + " ON DELETE " + first[6].display
        }
    }

    func applyObjectOperation(_ statements: [String], driver: DatabaseDriver) throws {
        if driver == .sqlite { try applySchema(statements, driver: .sqlite); return }
        guard !hasOpenTransaction else { throw BrowserError("Finish the current transaction before running DDL.") }
        for (index, statement) in statements.enumerated() {
            do { _ = try query(statement) }
            catch { throw BrowserError("Completed \(index) of \(statements.count) statements. \(error.localizedDescription)") }
        }
    }
}
