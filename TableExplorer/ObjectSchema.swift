import Foundation

struct ColumnInfo: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let type: String
    let nullable: Bool
    let defaultSQL: String?
    let keyOrder: Int
    let generated: Bool
    let automatic: Bool
}

struct ObjectSchema: Sendable {
    let columns: [ColumnInfo]
    let transactional: Bool
    var key: [ColumnInfo] { columns.filter { $0.keyOrder > 0 }.sorted { $0.keyOrder < $1.keyOrder } }
}

extension DatabaseSession {
    func schema(of object: DatabaseObject, driver: DatabaseDriver) throws -> ObjectSchema {
        switch driver {
        case .mariaDB:
            let description = try query("""
                SELECT c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, c.COLUMN_DEFAULT,
                       COALESCE(k.ORDINAL_POSITION,0), c.EXTRA, c.IS_GENERATED
                FROM information_schema.COLUMNS c
                LEFT JOIN information_schema.KEY_COLUMN_USAGE k
                  ON k.TABLE_SCHEMA=c.TABLE_SCHEMA AND k.TABLE_NAME=c.TABLE_NAME
                  AND k.COLUMN_NAME=c.COLUMN_NAME AND k.CONSTRAINT_NAME='PRIMARY'
                WHERE c.TABLE_SCHEMA=DATABASE() AND c.TABLE_NAME=? ORDER BY c.ORDINAL_POSITION
                """, parameters: [.text(object.name)], limit: .max)
            let columns = description.rows.map { row in
                ColumnInfo(name: row[0].display, type: row[1].display, nullable: row[2].display == "YES",
                           defaultSQL: row[3] == .null ? nil : row[3].display, keyOrder: Int(row[4].display) ?? 0,
                           generated: row[6].display == "ALWAYS", automatic: row[5].display.contains("auto_increment"))
            }
            let engine = try query("""
                SELECT e.TRANSACTIONS FROM information_schema.TABLES t
                JOIN information_schema.ENGINES e ON e.ENGINE=t.ENGINE
                WHERE t.TABLE_SCHEMA=DATABASE() AND t.TABLE_NAME=?
                """, parameters: [.text(object.name)])
            return ObjectSchema(columns: columns, transactional: engine.rows.first?.first?.display == "YES")
        case .sqlite:
            let meta = try query("SELECT name,type,\"notnull\",dflt_value,pk,hidden FROM pragma_table_xinfo(?) ORDER BY cid", parameters: [.text(object.name)], limit: .max)
            let keys = meta.rows.filter { $0[4].display != "0" }
            let usesRowID = try query("SELECT wr FROM pragma_table_list WHERE schema='main' AND name=?", parameters: [.text(object.name)]).rows.first?.first?.display == "0"
            // INTEGER PRIMARY KEY DESC has a real PK index and is not a rowid alias.
            let hasPKIndex = try query("SELECT 1 FROM pragma_index_list(?) WHERE origin='pk'", parameters: [.text(object.name)]).rows.first != nil
            let columns = meta.rows.filter { $0[5].display != "1" }.map { row in
                let order = Int(row[4].display) ?? 0
                return ColumnInfo(name: row[0].display, type: row[1].display, nullable: row[2].display == "0" && order == 0,
                                  defaultSQL: row[3] == .null ? nil : row[3].display, keyOrder: order, generated: row[5].display != "0",
                                  automatic: usesRowID && !hasPKIndex && keys.count == 1 && order == 1 && row[1].display.uppercased() == "INTEGER")
            }
            return ObjectSchema(columns: columns, transactional: true)
        }
    }

    func structure(_ object: DatabaseObject, driver: DatabaseDriver, section: String) throws -> QueryResult {
        let name = Self.identifier(object.name)
        if driver == .mariaDB {
            switch section {
            case "Columns": return try query("SHOW FULL COLUMNS FROM \(name)", limit: .max)
            case "Indexes": return try query("SHOW INDEX FROM \(name)", limit: .max)
            case "Foreign Keys":
                return try query("""
                    SELECT CONSTRAINT_NAME,ORDINAL_POSITION,COLUMN_NAME,REFERENCED_TABLE_SCHEMA,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME
                    FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?
                    AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY CONSTRAINT_NAME,ORDINAL_POSITION
                    """, parameters: [.text(object.name)], limit: .max)
            case "Triggers":
                return try query("""
                    SELECT TRIGGER_NAME,EVENT_OBJECT_TABLE,ACTION_TIMING,EVENT_MANIPULATION,ACTION_STATEMENT FROM information_schema.TRIGGERS
                    WHERE EVENT_OBJECT_SCHEMA=DATABASE() AND EVENT_OBJECT_TABLE=?
                    """, parameters: [.text(object.name)], limit: .max)
            default: return try query("SHOW CREATE \(object.kind.rawValue.uppercased()) \(name)")
            }
        }
        switch section {
        case "Columns": return try query("SELECT * FROM pragma_table_xinfo(?)", parameters: [.text(object.name)], limit: .max)
        case "Indexes":
            return try query("""
                SELECT l.name, l."unique", l.origin, l.partial, x.seqno, x.name AS column_name, x.desc, x.coll
                FROM pragma_index_list(?) l, pragma_index_xinfo(l.name) x WHERE x.key=1 ORDER BY l.seq,x.seqno
                """, parameters: [.text(object.name)], limit: .max)
        case "Foreign Keys": return try query("SELECT * FROM pragma_foreign_key_list(?)", parameters: [.text(object.name)], limit: .max)
        case "Triggers": return try query("SELECT name, tbl_name, sql FROM sqlite_schema WHERE type='trigger' AND tbl_name=?", parameters: [.text(object.name)], limit: .max)
        default: return try query("SELECT sql AS DDL FROM sqlite_schema WHERE name=? AND type=?", parameters: [.text(object.name), .text(object.kind == .view ? "view" : "table")])
        }
    }
}
