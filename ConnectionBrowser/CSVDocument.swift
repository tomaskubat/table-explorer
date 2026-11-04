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

    var stringEncoding: String.Encoding {
        switch encoding { case "UTF-16": .utf16; case "Latin-1": .isoLatin1; default: .utf8 }
    }
    func validate() throws {
        guard delimiter.unicodeScalars.count == 1, quote.unicodeScalars.count == 1, delimiter != quote,
              !["\n", "\r"].contains(delimiter), !["\n", "\r"].contains(quote) else {
            throw BrowserError("Choose distinct, single-character delimiters and quotes.")
        }
        guard !nullToken.contains(delimiter), !nullToken.contains(quote), !nullToken.contains("\n"), !nullToken.contains("\r") else {
            throw BrowserError("The NULL token cannot contain the delimiter, quote, or a line break.")
        }
    }
    func encode(_ field: String, forceQuote: Bool = false) -> String {
        if forceQuote || field.contains(delimiter) || field.contains(quote) || field.contains("\r") || field.contains("\n") {
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
                if !fields.isEmpty || !field.isEmpty || quoted {
                    endField()
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

extension DatabaseSession {
    func importCSV(_ document: CSVDocument, mapping: [String?], object: DatabaseObject, driver: DatabaseDriver) throws -> Int {
        let schema = try schema(of: object, driver: driver)
        let fields = mapping.compactMap { $0 }
        guard object.kind == .table, schema.transactional, !fields.isEmpty, Set(fields).count == fields.count,
              fields.allSatisfy({ name in schema.columns.contains { $0.name == name && !$0.generated } }) else {
            throw BrowserError("Map each source field to a distinct writable column, or choose Skip.")
        }
        guard !hasOpenTransaction else { throw BrowserError("Finish the current transaction before importing.") }
        let sql = "INSERT INTO " + Self.identifier(object.name) + " (" + fields.map(Self.identifier).joined(separator: ", ") + ") VALUES (" + fields.map { _ in "?" }.joined(separator: ", ") + ")"
        var inserted = 0, skipHeader = document.settings.header
        _ = try query(driver == .mariaDB ? "START TRANSACTION" : "BEGIN IMMEDIATE")
        do {
            try document.read { line, source in
                try Task.checkCancellation()
                if skipHeader { skipHeader = false; return true }
                guard source.count == mapping.count else { throw BrowserError("Line \(line): expected \(mapping.count) fields, found \(source.count).") }
                let values = zip(source, mapping).compactMap { field, target in target == nil ? nil : document.value(field) }
                do { _ = try query(sql, parameters: values) }
                catch { throw BrowserError("Line \(line), columns \(fields.joined(separator: ", ")): \(error.localizedDescription)") }
                inserted += 1; return true
            }
            _ = try query("COMMIT")
            return inserted
        } catch {
            do { _ = try query("ROLLBACK") }
            catch { throw BrowserError("Import failed and the transaction outcome could not be verified. Reconnect and inspect the target table.") }
            throw BrowserError("No rows were imported. \(error.localizedDescription)")
        }
    }
}
