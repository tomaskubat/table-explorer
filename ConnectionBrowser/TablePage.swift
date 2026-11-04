import Foundation

struct ColumnFilter: Identifiable, Hashable, Sendable {
    enum Operation: String, CaseIterable, Sendable { case contains = "Contains", equals = "Equals", isNull = "Is NULL", raw = "Raw SQL" }
    let id = UUID()
    var enabled = true
    var column: String
    var operation = Operation.contains
    var value = ""
}

struct TablePage: Sendable {
    let result: QueryResult
    let count: Int
    let offset: Int
    let sql: String
}

extension DatabaseSession {
    func page(of object: DatabaseObject, filters: [ColumnFilter], sortColumn: String?, descending: Bool,
              offset: Int, limit: Int) throws -> TablePage {
        let table = Self.identifier(object.name)
        var parameters: [SQLValue] = []
        let clauses = filters.filter(\.enabled).compactMap { filter -> String? in
            let column = Self.identifier(filter.column)
            switch filter.operation {
            case .isNull: return "\(column) IS NULL"
            case .equals: parameters.append(.text(filter.value)); return "\(column) = ?"
            case .contains:
                let escaped = filter.value.replacingOccurrences(of: "!", with: "!!")
                    .replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_")
                parameters.append(.text("%" + escaped + "%"))
                return "\(column) LIKE ? ESCAPE '!'"
            case .raw: return filter.value.isEmpty ? nil : "(\(filter.value))"
            }
        }
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let countResult = try query("SELECT COUNT(*) FROM \(table)\(predicate)", parameters: parameters)
        guard let cell = countResult.rows.first?.first, let count = Int(cell.display) else { throw BrowserError("Could not read the filtered row count.") }
        let size = min(max(1, limit), 10000)
        let start = min(max(offset, 0), (max(count - 1, 0) / size) * size)
        let order = sortColumn.map { " ORDER BY " + Self.identifier($0) + (descending ? " DESC" : " ASC") } ?? ""
        let sql = "SELECT * FROM \(table)\(predicate)\(order) LIMIT \(size) OFFSET \(start)"
        return try TablePage(result: query(sql, parameters: parameters, limit: size), count: count, offset: start, sql: sql)
    }
}
