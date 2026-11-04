import Foundation
import zlib

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
    var gzip = false
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
        var compressed: gzFile?
        if request.gzip {
            let descriptor = dup(output.fileDescriptor)
            guard descriptor >= 0 else { throw BrowserError("Could not open the gzip output stream.") }
            compressed = gzdopen(descriptor, "wb")
            guard compressed != nil else { Darwin.close(descriptor); throw BrowserError("Could not create the gzip encoder.") }
        }
        defer { if let compressed { gzclose(compressed) } }
        var buffer = Data()
        func flush() throws {
            guard !buffer.isEmpty else { return }
            try Task.checkCancellation()
            if let compressed {
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = min(bytes.count - offset, 65536)
                        guard gzwrite(compressed, bytes.baseAddress! + offset, UInt32(count)) == Int32(count) else {
                            throw BrowserError("Could not write compressed SQL to the destination.")
                        }
                        offset += count
                    }
                }
            } else { try output.write(contentsOf: buffer) }
            buffer.removeAll(keepingCapacity: true)
        }
        func write(_ string: String) throws {
            buffer.append(contentsOf: string.utf8)
            if buffer.count >= 64 * 1024 { try flush() }
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
                    let text: String
                    switch value {
                    case let .number(number): text = request.csv.decimalComma ? number.replacingOccurrences(of: ".", with: ",") : number
                    case let .blob(bytes): text = bytes.base64EncodedString()
                    default: text = value.display
                    }
                    return request.csv.encode(text)
                }
                try write(fields.joined(separator: request.csv.delimiter) + newline)
            case .json:
                var record: [String: Any] = [:]
                for (key, value) in zip(request.columns, values) {
                    record[key] = try value.jsonValue()
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
        if request.format == .sql && request.driver == .sqlite && request.includeDDL, let object = request.object {
            let extras = try query("SELECT sql FROM sqlite_schema WHERE tbl_name=? AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY type,name",
                                   parameters: [.text(object.name)], limit: .max)
            for row in extras.rows { try write(row[0].display + ";\n") }
        }
        try flush()
        if let stream = compressed {
            compressed = nil
            guard gzclose(stream) == Z_OK else { throw BrowserError("Could not finish the gzip file.") }
        }
        try Task.checkCancellation()
        try output.synchronize()
        try output.close()
        if request.overwrite && manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: temporary)
        } else { try manager.moveItem(at: temporary, to: destination) }
        return written
    }
}
