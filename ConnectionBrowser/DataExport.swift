import Foundation

enum ExportFormat: String, CaseIterable, Sendable { case csv = "CSV", json = "JSON", sql = "SQL" }
enum ExportScope: String, CaseIterable, Sendable { case result = "Current Result", selected = "Selected Rows", filtered = "Filtered Rows", table = "Entire Table" }

struct ExportRequest: Sendable {
    let destination: URL
    let overwrite: Bool
    let driver: DatabaseDriver
    let format: ExportFormat
    let scope: ExportScope
    let csv: CSVSettings
    let object: DatabaseObject?
    let columns: [String]
    let rows: [[SQLValue]]
    let read: TableRead?
    let includeDDL: Bool
    let includeData: Bool
    let includeDrop: Bool
    let outputTable: String
}

extension DatabaseSession {
    func export(_ request: ExportRequest) throws -> Int {
        guard !request.columns.isEmpty else { throw BrowserError("Select at least one field to export.") }
        guard Set(request.columns).count == request.columns.count || request.format == .csv else {
            throw BrowserError("Use unique column aliases for JSON or SQL export.")
        }
        if request.format == .csv { try request.csv.validate() }
        let manager = FileManager.default
        let destination = request.destination
        try checkExportDestination(destination)
        let temporary = destination.deletingLastPathComponent().appending(path: "." + UUID().uuidString + ".partial")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BrowserError("Could not create an export in the selected directory.")
        }
        defer { try? manager.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var buffer = Data()
        func write(_ string: String) throws {
            buffer.append(contentsOf: string.utf8)
            if buffer.count >= 64 * 1024 { try output.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        let newline = request.csv.lineEnding == "CRLF" ? "\r\n" : "\n"
        var written = 0
        switch request.format {
        case .csv:
            if request.csv.header { try write(request.columns.map { request.csv.encode($0) }.joined(separator: request.csv.delimiter) + newline) }
        case .json: try write("[")
        case .sql:
            let kind = request.object?.kind == .view ? "VIEW" : "TABLE"
            if request.includeDrop { try write("DROP \(kind) IF EXISTS \(Self.identifier(request.outputTable));\n") }
            if request.includeDDL, let object = request.object {
                let result = try structure(object, driver: request.driver, section: "DDL")
                guard let ddl = result.rows.first?.first(where: { $0.display.uppercased().contains("CREATE ") }) else { throw BrowserError("The server did not return the object definition.") }
                try write(ddl.display + ";\n")
            }
        }

        func row(_ values: [SQLValue]) throws {
            if Task.isCancelled { throw CancellationError() }
            guard values.count == request.columns.count else { throw BrowserError("The source columns changed during export.") }
            switch request.format {
            case .csv:
                let fields = values.map { value in
                    if value == .null { return request.csv.nullToken }
                    return request.csv.encode(value.display, forceQuote: value.display == request.csv.nullToken)
                }
                try write(fields.joined(separator: request.csv.delimiter) + newline)
            case .json:
                var record: [String: Any] = [:]
                for (key, value) in zip(request.columns, values) {
                    switch value {
                    case .null: record[key] = NSNull()
                    case .text(let text): record[key] = text
                    case .integer(let text), .number(let text):
                        let numeric = NSDecimalNumber(string: text, locale: Locale(identifier: "en_US_POSIX"))
                        guard numeric != .notANumber else { throw BrowserError("Column \(key) contains a number outside JSON's supported range.") }
                        record[key] = numeric
                    case .blob(let bytes): record[key] = bytes.base64EncodedString()
                    }
                }
                if written > 0 { try write(",") }
                try write("\n" + String(decoding: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
            case .sql:
                let fields = request.columns.map(Self.identifier).joined(separator: ", ")
                let literals = values.map { ChangeSQL.literal($0, driver: request.driver) }.joined(separator: ", ")
                try write("INSERT INTO \(Self.identifier(request.outputTable)) (\(fields)) VALUES (\(literals));\n")
            }
            written += 1
        }

        if request.format != .sql || request.includeData {
            if let query = request.read {
                let projection = request.columns.map(Self.identifier).joined(separator: ", ")
                _ = try read("SELECT \(projection)" + query.from + query.order, parameters: query.parameters, limit: .max, visit: row)
            } else {
                for values in request.rows { try row(values) }
            }
        }
        if request.format == .json { try write("\n]\n") }
        if !buffer.isEmpty { try output.write(contentsOf: buffer) }
        try output.synchronize()
        try output.close()
        if request.overwrite && manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else { try manager.moveItem(at: temporary, to: destination) }
        return written
    }
}
