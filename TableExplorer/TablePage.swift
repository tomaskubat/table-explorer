import Foundation

struct ColumnFilter: Identifiable, Hashable, Codable, Sendable {
    enum Operation: String, CaseIterable, Codable, Sendable { case contains = "Contains", equals = "Equals", notEquals = "Not equal", less = "Less than", greater = "Greater than", isNull = "Is NULL", notNull = "Is not NULL", raw = "Raw SQL" }
    var id = UUID()
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
    let statements: [ConsoleEntry]
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
              offset: Int, limit: Int, keyColumns: [String],
              firstRows: (@Sendable (QueryResult) -> Void)? = nil) throws -> TablePage {
        let read = TableRead(object: object, filters: filters, sortColumn: sortColumn, descending: descending, keyColumns: keyColumns)
        let size = min(max(1, limit), 10000)
        var statements: [ConsoleEntry] = []
        func select(at start: Int) throws -> QueryResult {
            let sql = "SELECT *" + read.from + read.order + " LIMIT \(size) OFFSET \(start)"
            statements.append(ConsoleEntry(text: sql))
            return try query(sql, parameters: read.parameters, limit: size)
        }
        func countRows() throws -> Int {
            let sql = "SELECT COUNT(*)" + read.from
            statements.append(ConsoleEntry(text: sql))
            guard let cell = try query(sql, parameters: read.parameters).rows.first?.first, let count = Int(cell.display)
            else { throw BrowserError("Could not read the filtered row count.") }
            return count
        }
        if offset <= 0 {
            let rows = try select(at: 0)
            var count = rows.rows.count
            if count == size {
                firstRows?(rows)
                count = try countRows()
            }
            return TablePage(result: rows, count: count, offset: 0, statements: statements)
        }
        let count = try countRows()
        let start = min(max(offset, 0), (max(count - 1, 0) / size) * size)
        let rows = try select(at: start)
        return TablePage(result: rows, count: count, offset: start, statements: statements)
    }
}
