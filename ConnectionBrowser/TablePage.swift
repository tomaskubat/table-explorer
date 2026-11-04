import Foundation

struct ColumnFilter: Identifiable, Hashable, Sendable {
    enum Operation: String, CaseIterable, Sendable { case contains = "Contains", equals = "Equals", notEquals = "Not equal", less = "Less than", greater = "Greater than", isNull = "Is NULL", notNull = "Is not NULL", raw = "Raw SQL" }
    let id = UUID()
    var enabled = true
    var column: String
    var operation = Operation.contains
    var value = ""
    var typed: SQLValue?
}

struct TablePage: Sendable {
    let result: QueryResult
    let count: Int
    let offset: Int
    let sql: String
}

struct TableRead: Sendable {
    let from: String
    let order: String
    let parameters: [SQLValue]
    init(object: DatabaseObject, filters: [ColumnFilter], sortColumn: String?, descending: Bool, keyColumns: [String] = []) {
        let table = DatabaseSession.identifier(object.name)
        var parameters: [SQLValue] = []
        let clauses = filters.filter(\.enabled).compactMap { filter -> String? in
            let column = DatabaseSession.identifier(filter.column)
            switch filter.operation {
            case .isNull: return "\(column) IS NULL"
            case .notNull: return "\(column) IS NOT NULL"
            case .equals, .notEquals, .less, .greater:
                let operators: [ColumnFilter.Operation: String] = [.equals: "=", .notEquals: "<>", .less: "<", .greater: ">"]
                parameters.append(filter.typed ?? .text(filter.value))
                return "\(column) \(operators[filter.operation]!) ?"
            case .contains:
                let escaped = filter.value.replacingOccurrences(of: "!", with: "!!")
                    .replacingOccurrences(of: "%", with: "!%").replacingOccurrences(of: "_", with: "!_")
                parameters.append(.text("%" + escaped + "%"))
                return "\(column) LIKE ? ESCAPE '!'"
            case .raw: return filter.value.isEmpty ? nil : "(\(filter.value))"
            }
        }
        let predicate = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        self.from = " FROM " + table + predicate
        var terms = sortColumn.map { [DatabaseSession.identifier($0) + (descending ? " DESC" : " ASC")] } ?? []
        terms += keyColumns.filter { $0 != sortColumn }.map(DatabaseSession.identifier)
        self.order = terms.isEmpty ? "" : " ORDER BY " + terms.joined(separator: ", ")
        self.parameters = parameters
    }
}

extension DatabaseSession {
    func page(of object: DatabaseObject, filters: [ColumnFilter], sortColumn: String?, descending: Bool,
              offset: Int, limit: Int, keyColumns: [String]) throws -> TablePage {
        let read = TableRead(object: object, filters: filters, sortColumn: sortColumn, descending: descending, keyColumns: keyColumns)
        let countResult = try query("SELECT COUNT(*)" + read.from, parameters: read.parameters)
        guard let cell = countResult.rows.first?.first, let count = Int(cell.display) else { throw BrowserError("Could not read the filtered row count.") }
        let size = min(max(1, limit), 10000)
        let start = min(max(offset, 0), (max(count - 1, 0) / size) * size)
        let sql = "SELECT *" + read.from + read.order + " LIMIT \(size) OFFSET \(start)"
        return try TablePage(result: query(sql, parameters: read.parameters, limit: size), count: count, offset: start, sql: sql)
    }
}
