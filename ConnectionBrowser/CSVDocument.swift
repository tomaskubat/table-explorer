import Foundation

struct CSVField: Sendable {
    let text: String
    let quoted: Bool
}

struct CSVSettings: Hashable, Sendable {
    var delimiter = BrowserPreferences.defaults.string(forKey: "csvSeparator") ?? ","
    var quote = "\""
    var header = BrowserPreferences.defaults.object(forKey: "csvHeader") as? Bool ?? true
    var nullToken = BrowserPreferences.defaults.string(forKey: "csvNull") ?? "\\N"
    var encoding = "UTF-8"
    var lineEnding = "LF"
    var quoteAll = false
    var decimalComma = false
    var flattenLineBreaks = false

    var stringEncoding: String.Encoding {
        switch encoding { case "UTF-16": .utf16; case "Latin-1": .isoLatin1; default: .utf8 }
    }
    func validate() throws {
        guard delimiter.unicodeScalars.count == 1, quote.unicodeScalars.count == 1, delimiter != quote,
              !["\n", "\r"].contains(delimiter), !["\n", "\r"].contains(quote) else {
            throw BrowserError("Choose distinct, single-character delimiters and quotes.")
        }
        guard !nullToken.contains(delimiter), !nullToken.contains(quote), !nullToken.contains(where: \.isNewline) else {
            throw BrowserError("The NULL token cannot contain the delimiter, quote, or a line break.")
        }
    }
    func encode(_ original: String) -> String {
        // Swift treats CRLF as a single Character. Looking for either half as
        // a substring misses it and silently splits a CSV record into two.
        let hasBreak = original.contains(where: \.isNewline)
        let field = flattenLineBreaks && hasBreak ? String(original.map { $0.isNewline ? " " : $0 }) : original
        if quoteAll || field.isEmpty || field == nullToken || (hasBreak && !flattenLineBreaks) || field.contains(delimiter) || field.contains(quote) {
            return quote + field.replacingOccurrences(of: quote, with: quote + quote) + quote
        }
        return field
    }
}

struct CSVDocument: Sendable {
    let text: String
    let settings: CSVSettings

    init(file: URL, settings: CSVSettings) throws {
        try settings.validate()
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: settings.stringEncoding) else { throw BrowserError("The file is not valid \(settings.encoding).") }
        self.text = text; self.settings = settings
    }

    /// Return false from the visitor to stop without parsing the rest of the file.
    func read(_ visit: (Int, [CSVField]) throws -> Bool) throws {
        let delimiter = settings.delimiter.unicodeScalars.first!
        let quote = settings.quote.unicodeScalars.first!
        var scalars = text.unicodeScalars.makeIterator()
        var ch = scalars.next()
        if ch == "\u{FEFF}" { ch = scalars.next() }
        var fields: [CSVField] = [], field = "", quoted = false, inside = false, closed = false
        var line = 1, startLine = 1
        var recordWidth: Int?
        func endField() {
            fields.append(CSVField(text: field, quoted: quoted))
            field = ""; quoted = false; closed = false
        }
        while let current = ch {
            let next = scalars.next()
            if inside {
                if current == quote {
                    if next == quote { field.unicodeScalars.append(quote); ch = scalars.next(); continue }
                    inside = false; closed = true
                } else {
                    field.unicodeScalars.append(current)
                    if current == "\n" || (current == "\r" && next != "\n") { line += 1 }
                }
            } else if current == delimiter { endField() }
            else if current == "\r" || current == "\n" {
                let blankNull = settings.nullToken.isEmpty && (recordWidth == 1 || (recordWidth == nil && !settings.header))
                if !fields.isEmpty || !field.isEmpty || quoted || blankNull {
                    endField()
                    if recordWidth == nil { recordWidth = fields.count }
                    if try !visit(startLine, fields) { return }
                    fields.removeAll(keepingCapacity: true)
                }
                line += 1; startLine = line
                if current == "\r" && next == "\n" { ch = scalars.next(); continue }
            } else if current == quote && field.isEmpty && !closed {
                quoted = true; inside = true
            } else if closed || current == quote {
                throw BrowserError("Line \(line), field \(fields.count + 1): unexpected character near a quote.")
            } else { field.unicodeScalars.append(current) }
            ch = next
        }
        guard !inside else { throw BrowserError("Line \(startLine), field \(fields.count + 1): missing closing quote.") }
        if !fields.isEmpty || !field.isEmpty || quoted { endField(); _ = try visit(startLine, fields) }
    }

    func preview() throws -> QueryResult {
        var result = QueryResult()
        try read { line, fields in
            if result.columns.isEmpty {
                result.columns = settings.header ? fields.map(\.text) : fields.indices.map { "Field \($0 + 1)" }
                if settings.header { return true }
            }
            guard fields.count == result.columns.count else { throw BrowserError("Line \(line): expected \(result.columns.count) fields, found \(fields.count).") }
            if result.rows.count == 100 { result.truncated = true; return false }
            result.rows.append(fields.map(value))
            return true
        }
        if result.columns.isEmpty { throw BrowserError("The file is empty.") }
        return result
    }

    func value(_ field: CSVField) -> SQLValue {
        !field.quoted && field.text == settings.nullToken ? .null : .text(field.text)
    }
}

struct CSVImportColumn: Identifiable, Sendable {
    enum Storage: String, CaseIterable, Sendable {
        case text = "Text", integer = "Integer", decimal = "Real", blob = "Blob"

        func sql(_ driver: DatabaseDriver) -> String {
            switch self {
            case .text: return "TEXT"
            case .integer: return driver == .mariaDB ? "BIGINT" : "INTEGER"
            case .decimal: return driver == .mariaDB ? "DOUBLE" : "REAL"
            case .blob: return "BLOB"
            }
        }
    }
    let id = UUID()
    var name: String
    var storage = Storage.text
    var include = true

    func convert(_ value: SQLValue) throws -> SQLValue {
        guard case let .text(raw) = value else { return value }
        switch storage {
        case .text: return value
        case .integer:
            if let number = Int64(raw) { return .integer(String(number)) }
        case .decimal:
            if let number = Double(raw), number.isFinite { return .number(String(number)) }
        case .blob:
            if let bytes = Data(base64Encoded: raw) { return .blob(bytes) }
        }
        throw BrowserError("Column " + name + " expects " + (storage == .blob ? "Base64-encoded bytes" : storage.rawValue.lowercased()) + ".")
    }

    static func createTable(_ name: String, columns: [Self], driver: DatabaseDriver) throws -> String {
        let chosen = columns.filter(\.include)
        let names = chosen.map(\.name)
        guard ([name] + names).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("\0") }),
              !chosen.isEmpty, Set(names.map { $0.lowercased() }).count == names.count else {
            throw BrowserError("Enter a table name and a distinct name for each included column.")
        }
        let fields = chosen.map { DatabaseSession.identifier($0.name) + " " + $0.storage.sql(driver) }
        return "CREATE TABLE " + DatabaseSession.identifier(name) + " (" + fields.joined(separator: ", ") + ")" + (driver == .mariaDB ? " ENGINE=InnoDB" : "")
    }
}

extension DatabaseSession {
    func importCSV(_ document: CSVDocument, mapping: [String?], object: DatabaseObject, driver: DatabaseDriver,
                   newColumns: [CSVImportColumn]? = nil) throws -> Int {
        guard !hasOpenTransaction else { throw BrowserError("Finish the current transaction before importing.") }
        let fields = mapping.compactMap { $0 }
        guard object.kind == .table, !fields.isEmpty, Set(fields).count == fields.count else {
            throw BrowserError("Map each source field to a distinct writable column, or choose Skip.")
        }
        // MariaDB commits CREATE TABLE implicitly. Publish the complete staging
        // table only after every row commits. RENAME refuses an existing target.
        let stage = newColumns != nil && driver == .mariaDB ? "_csv_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") : nil
        let destination = Self.identifier(stage ?? object.name)
        let ddl: String?
        if let newColumns {
            _ = try CSVImportColumn.createTable(object.name, columns: newColumns, driver: driver)
            ddl = try CSVImportColumn.createTable(stage ?? object.name, columns: newColumns, driver: driver)
        } else {
            let schema = try schema(of: object, driver: driver)
            guard schema.transactional, fields.allSatisfy({ name in schema.columns.contains { $0.name == name && !$0.generated } }) else {
                throw BrowserError("Select a transactional table and map only its writable columns.")
            }
            ddl = nil
        }
        let sql = "INSERT INTO " + destination + " (" + fields.map(Self.identifier).joined(separator: ", ") + ") VALUES (" + fields.map { _ in "?" }.joined(separator: ", ") + ")"
        var inserted = 0, skipHeader = document.settings.header, transaction = false, createdStage = false
        do {
            if let ddl, stage != nil { _ = try query(ddl); createdStage = true }
            _ = try query(driver == .mariaDB ? "START TRANSACTION" : "BEGIN IMMEDIATE")
            transaction = true
            if let ddl, stage == nil { _ = try query(ddl) }
            try document.read { line, source in
                try Task.checkCancellation()
                if skipHeader { skipHeader = false; return true }
                guard source.count == mapping.count else { throw BrowserError("Line \(line): expected \(mapping.count) fields, found \(source.count).") }
                do {
                    let values = try source.indices.compactMap { index -> SQLValue? in
                        guard mapping[index] != nil else { return nil }
                        let value = document.value(source[index])
                        return try newColumns?[index].convert(value) ?? value
                    }
                    _ = try query(sql, parameters: values)
                }
                catch { throw BrowserError("Line \(line), columns \(fields.joined(separator: ", ")): \(error.localizedDescription)") }
                inserted += 1; return true
            }
            try Task.checkCancellation()
            _ = try query("COMMIT"); transaction = false
            if stage != nil {
                try Task.checkCancellation()
                _ = try query("RENAME TABLE " + destination + " TO " + Self.identifier(object.name))
            }
            return inserted
        } catch {
            let cause = error.localizedDescription
            do {
                if transaction { _ = try query("ROLLBACK") }
                if createdStage { _ = try query("DROP TABLE " + destination) }
            } catch {
                let detail = stage.map { " Check the staging table " + $0 + "." } ?? ""
                throw BrowserError(cause + "\nCould not verify the transaction or clean up the import. Reconnect and inspect the target." + detail)
            }
            throw BrowserError("No rows were imported. " + cause)
        }
    }
}
