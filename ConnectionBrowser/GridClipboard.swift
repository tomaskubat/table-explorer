import Foundation

enum GridTransfer { case importCSV, exportPage, exportTable }
enum RowCopyFormat: String, CaseIterable { case text = "Plain Text", json = "JSON", html = "HTML", markdown = "Markdown Table", csv = "CSV", csvHeader = "CSV with Header", sql = "SQL INSERT Statements" }

extension SQLValue {
    func jsonValue() throws -> Any {
        switch self {
        case .null: return NSNull()
        case .text(let text): return text
        case .integer(let text), .number(let text):
            let number = NSDecimalNumber(string: text, locale: Locale(identifier: "en_US_POSIX"))
            guard number != .notANumber else { throw BrowserError("The value is outside JSON's numeric range.") }
            return number
        case .blob(let bytes): return bytes.base64EncodedString()
        }
    }
}

enum GridClipboard {
    static func encode(_ rows: [[SQLValue]], fields: [String], format: RowCopyFormat, table: String, driver: DatabaseDriver) throws -> String {
        switch format {
        case .text: return rows.map { $0.map(\.display).joined(separator: "\t") }.joined(separator: "\n")
        case .csv, .csvHeader:
            var options = CSVSettings(); options.delimiter = ","
            let lines = rows.map { row in row.map { $0 == .null ? options.nullToken : options.encode($0.display, forceQuote: $0.display == options.nullToken) }.joined(separator: ",") }
            return ((format == .csvHeader ? [fields.map { options.encode($0) }.joined(separator: ",")] : []) + lines).joined(separator: "\n")
        case .json:
            let objects = try rows.map { row in try Dictionary(uniqueKeysWithValues: zip(fields, row.map { try $0.jsonValue() })) }
            return String(decoding: try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        case .sql:
            return rows.map { "INSERT INTO \(DatabaseSession.identifier(table)) (" + fields.map(DatabaseSession.identifier).joined(separator: ", ") + ") VALUES (" + $0.map { ChangeSQL.literal($0, driver: driver) }.joined(separator: ", ") + ");" }.joined(separator: "\n")
        case .markdown:
            func line(_ values: [String]) -> String {
                "| " + values.map { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |"
            }
            return ([line(fields), line(fields.map { _ in "---" })] + rows.map { line($0.map(\.display)) }).joined(separator: "\n")
        case .html:
            func line(_ values: [String], tag: String) -> String {
                "<tr>" + values.map {
                    "<\(tag)>" + $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") + "</\(tag)>"
                }.joined() + "</tr>"
            }
            return "<table><thead>" + line(fields, tag: "th") + "</thead><tbody>" + rows.map { line($0.map(\.display), tag: "td") }.joined() + "</tbody></table>"
        }
    }
}
