import AppKit

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
            let lines = rows.map { row in row.map { $0 == .null ? options.nullToken : options.encode($0.display) }.joined(separator: ",") }
            return ((format == .csvHeader ? [fields.map { options.encode($0) }.joined(separator: ",")] : []) + lines).joined(separator: "\n")
        case .json:
            guard Set(fields).count == fields.count else { throw BrowserError("Use unique column aliases for JSON.") }
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

    static func uniqueFields(_ fields: [String]) -> [String] {
        let originals = Set(fields.map { $0.lowercased() })
        var used: Set<String> = []
        return fields.map { field in
            let base = field.isEmpty ? "column" : field
            if used.insert(base.lowercased()).inserted { return base }
            var index = 2
            while true {
                let candidate = "\(base)_\(index)"
                if !originals.contains(candidate.lowercased()), used.insert(candidate.lowercased()).inserted { return candidate }
                index += 1
            }
        }
    }

    static func dump(_ rows: [[SQLValue]], fields: [String], table: String, driver: DatabaseDriver) throws -> String {
        let columns = fields.enumerated().map { index, field in
            let name = DatabaseSession.identifier(field)
            guard driver == .mariaDB else { return name }
            let values = rows.lazy.map { $0[index] }
            let type: String
            switch values.first(where: { $0 != .null }) {
            case .blob: type = "LONGBLOB"
            case .integer: type = "DECIMAL(20,0)"
            case .number: type = "DOUBLE"
            default: type = "LONGTEXT CHARACTER SET utf8mb4"
            }
            return name + " " + type
        }
        let ddl = "CREATE TABLE \(DatabaseSession.identifier(table)) (\(columns.joined(separator: ", ")));"
        guard !rows.isEmpty else { return ddl }
        return ddl + "\n" + (try encode(rows, fields: fields, format: .sql, table: table, driver: driver))
    }

    @MainActor static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor enum GridContextMenu {
    // NSMenuItem keeps its represented object alive for the duration of the menu.
    private final class Action: NSObject {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
        @MainActor @objc func apply(_ sender: Any?) { handler() }
    }

    @discardableResult static func item(_ title: String, in menu: NSMenu, enabled: Bool = true, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = Action(action)
        let item = NSMenuItem(title: title, action: #selector(Action.apply(_:)), keyEquivalent: "")
        item.target = target; item.representedObject = target; item.isEnabled = enabled; menu.addItem(item)
        return item
    }

    static func submenu(_ title: String, in menu: NSMenu) -> NSMenu {
        let child = NSMenu(title: title); child.autoenablesItems = false
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: ""); entry.submenu = child; menu.addItem(entry)
        return child
    }
}
