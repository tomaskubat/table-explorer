import Foundation

struct SQLFilterCompletion: Identifiable, Equatable {
    let title: String
    let detail: String
    let insertion: String
    let range: NSRange
    var selection: NSRange?
    var id: String { title + insertion }

    func applying(to text: String) -> (text: String, selection: NSRange) {
        let source = text as NSString
        guard NSMaxRange(range) <= source.length else { return (text, NSRange(location: source.length, length: 0)) }
        let result = source.replacingCharacters(in: range, with: insertion)
        let target = selection.map { NSRange(location: range.location + $0.location, length: $0.length) }
            ?? NSRange(location: range.location + insertion.utf16.count, length: 0)
        return (result, target)
    }
}

/// Suggestions for WHERE predicates. The lexer keeps literals and quoted names intact;
/// unsupported expressions simply retain normal SQL text editing.
enum SQLFilterCompleter {
    private enum Kind { case word, identifier, literal, number, symbol, comment }
    private struct Token {
        let text: String
        let range: NSRange
        let kind: Kind
        var closed = true
        var keyword: String { text.uppercased() }
        var name: String {
            guard kind == .identifier else { return text }
            let start = text.first!, end: Character = start == "[" ? "]" : start
            let body = closed ? text.dropFirst().dropLast() : text.dropFirst()
            return String(body).replacingOccurrences(of: String(repeating: String(end), count: 2), with: String(end))
        }
    }
    private enum ValueMode { case single, betweenFirst, betweenSecond, list }
    private enum Stage {
        case column, comparison(ColumnInfo?), value(ColumnInfo?, ValueMode), betweenAnd(ColumnInfo?), listEnd(ColumnInfo?), isValue(Bool), continuation
    }
    private enum Affinity { case text, number, boolean, date, binary, unknown }

    static func suggestions(in text: String, selection: NSRange, columns: [ColumnInfo], driver: DatabaseDriver,
                            explicit: Bool = false) -> [SQLFilterCompletion] {
        let source = text as NSString
        guard selection.length == 0, selection.location != NSNotFound, selection.location <= source.length else { return [] }
        let cursor = selection.location
        var tokens = lex(source.substring(to: cursor), driver: driver)
        if let last = tokens.last, !last.closed, last.kind == .literal || last.kind == .comment { return [] }
        var prefix = "", range = NSRange(location: cursor, length: 0)
        if let last = tokens.last, NSMaxRange(last.range) == cursor,
           last.kind == .word || (last.kind == .identifier && !last.closed) || (last.kind == .symbol && ["=", "<", ">", "!", "<>", ">=", "<=", "!="].contains(last.text)) {
            prefix = last.name
            range = last.range
            tokens.removeLast()
            if let whole = lex(text, driver: driver).first(where: { $0.range.location == range.location }) { range = whole.range }
        }
        tokens.removeAll { $0.kind == .comment }
        var stage = Stage.column, groups = 0, negated = false
        for token in tokens {
            switch stage {
            case .column:
                if token.text == "(" { groups += 1 }
                else if token.keyword != "NOT" {
                    guard token.kind == .word || token.kind == .identifier else { return [] }
                    stage = .comparison(columns.first { $0.name.caseInsensitiveCompare(token.name) == .orderedSame })
                    negated = false
                }
            case .comparison(let column):
                switch token.keyword {
                case ".": stage = .column
                case "NOT": negated = true
                case "IS": stage = .isValue(false)
                case "BETWEEN": stage = .value(column, .betweenFirst)
                case "IN": stage = .value(column, .list)
                case "=", "<>", "!=", ">", "<", ">=", "<=", "LIKE", "GLOB", "REGEXP": stage = .value(column, .single)
                default: return []
                }
            case .value(let column, let mode):
                if token.text == "(" && mode == .list { continue }
                if ["+", "-"].contains(token.text) { continue }
                guard token.kind == .literal || token.kind == .number || token.kind == .word || token.kind == .identifier else { return [] }
                switch mode {
                case .single, .betweenSecond: stage = .continuation
                case .betweenFirst: stage = .betweenAnd(column)
                case .list: stage = .listEnd(column)
                }
            case .betweenAnd(let column):
                guard token.keyword == "AND" else { return [] }
                stage = .value(column, .betweenSecond)
            case .listEnd(let column):
                if token.text == "," { stage = .value(column, .list) }
                else if token.text == ")" { stage = .continuation }
                else { return [] }
            case .isValue:
                if token.keyword == "NOT" { stage = .isValue(true) }
                else if ["NULL", "TRUE", "FALSE"].contains(token.keyword) { stage = .continuation }
                else { return [] }
            case .continuation:
                if token.keyword == "AND" || token.keyword == "OR" { stage = .column }
                else if token.text == ")", groups > 0 { groups -= 1 }
                else { return [] }
            }
        }
        // Replace an existing separating space together with the token, so accepting
        // a completion in the middle of a predicate does not duplicate spaces.
        if NSMaxRange(range) < source.length, source.character(at: NSMaxRange(range)) == 32 { range.length += 1 }
        func matches(_ value: String) -> Bool { prefix.isEmpty || value.range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }
        func item(_ title: String, detail: String = "", insert: String? = nil, selection: NSRange? = nil) -> SQLFilterCompletion {
            var insertion = insert ?? title + " "
            var target = selection
            if range.location > 0, UnicodeScalar(source.character(at: range.location - 1)).map({ CharacterSet.whitespacesAndNewlines.contains($0) }) != true,
               case .comparison = stage {
                insertion = " " + insertion
                if let selected = target { target = NSRange(location: selected.location + 1, length: selected.length) }
            }
            return SQLFilterCompletion(title: title, detail: detail, insertion: insertion, range: range, selection: target)
        }
        func names() -> [SQLFilterCompletion] {
            columns.filter { matches($0.name) }.prefix(30).map {
                item($0.name, detail: $0.type, insert: DatabaseSession.identifier($0.name) + " ")
            }
        }
        switch stage {
        case .column:
            return prefix.isEmpty && !explicit ? [] : names()
        case .comparison(let column):
            var operators = negated ? ["BETWEEN", "IN"] : ["=", "<>", ">", ">=", "<", "<=", "BETWEEN", "NOT BETWEEN", "IN", "NOT IN"]
            let type = affinity(column?.type ?? "")
            if type == .text || type == .unknown { operators += negated ? ["LIKE"] : ["LIKE", "NOT LIKE"] }
            if !negated, column?.nullable != false { operators += ["IS NULL", "IS NOT NULL"] }
            return operators.filter(matches).map { item($0, detail: column?.type ?? "SQL condition", insert: $0.hasSuffix("IN") ? $0 + " (" : $0 + " ") }
        case .value(let column, _):
            var result: [SQLFilterCompletion] = []
            if prefix.isEmpty {
                switch affinity(column?.type ?? "") {
                case .text, .unknown:
                    result.append(item("'text'", detail: "Text value", insert: "'' ", selection: NSRange(location: 1, length: 0)))
                case .number:
                    result.append(item("number", detail: column?.type ?? "Number", insert: "0 ", selection: NSRange(location: 0, length: 1)))
                case .binary:
                    result.append(item("X'hex'", detail: "Binary value", insert: "X'' ", selection: NSRange(location: 2, length: 0)))
                case .date, .boolean: break
                }
            }
            let constants: [String]
            switch affinity(column?.type ?? "") {
            case .boolean: constants = ["TRUE", "FALSE"]
            case .date: constants = ["CURRENT_DATE", "CURRENT_TIMESTAMP"]
            default: constants = []
            }
            result += constants.filter(matches).map { item($0, detail: column?.type ?? "SQL value") }
            if !prefix.isEmpty { result += names() }
            return result
        case .betweenAnd:
            return matches("AND") ? [item("AND", detail: "Upper bound of BETWEEN")] : []
        case .listEnd:
            return prefix.isEmpty ? [item(")", detail: "Finish IN list"), item(",", detail: "Another value")] : []
        case .isValue(let negated):
            return (negated ? ["NULL", "TRUE", "FALSE"] : ["NULL", "NOT NULL", "TRUE", "FALSE"]).filter(matches).map { item($0) }
        case .continuation:
            if prefix.isEmpty { return groups > 0 ? [item(")", detail: "Close condition group")] : [] }
            return ["AND", "OR"].filter(matches).map { item($0, detail: "Another condition") }
        }
    }

    private static func affinity(_ type: String) -> Affinity {
        let type = type.uppercased().replacingOccurrences(of: " ", with: "")
        if type.contains("BOOL") || type.hasPrefix("TINYINT(1)") { return .boolean }
        if type.contains("DATE") || type.contains("TIME") { return .date }
        if ["INT", "REAL", "NUM", "DEC", "FLOAT", "DOUBLE", "BIT"].contains(where: type.contains) { return .number }
        if type.contains("BLOB") || type.contains("BINARY") { return .binary }
        if ["TEXT", "CHAR", "CLOB", "ENUM", "SET", "JSON"].contains(where: type.contains) { return .text }
        return .unknown
    }

    private static func lex(_ text: String, driver: DatabaseDriver) -> [Token] {
        let source = text as NSString
        var result: [Token] = [], i = 0
        func ch(_ index: Int) -> unichar { index < source.length ? source.character(at: index) : 0 }
        func word(_ char: unichar) -> Bool {
            char == 95 || char == 36 || UnicodeScalar(char).map { CharacterSet.alphanumerics.contains($0) } == true
        }
        while i < source.length {
            if ch(i) <= 32 { i += 1; continue }
            let start = i, first = ch(i)
            var kind = Kind.symbol, closed = true
            if (first == 45 && ch(i + 1) == 45 && (driver == .sqlite || ch(i + 2) <= 32)) || (first == 35 && driver == .mariaDB) {
                kind = .comment
                while i < source.length && ch(i) != 10 { i += 1 }
                closed = i < source.length
            } else if first == 47 && ch(i + 1) == 42 {
                kind = .comment; i += 2
                while i < source.length && !(ch(i) == 42 && ch(i + 1) == 47) { i += 1 }
                closed = i < source.length
                if closed { i += 2 }
            } else if [39, 34, 96].contains(first) || (first == 91 && driver == .sqlite) {
                kind = first == 39 ? .literal : .identifier
                let end: unichar = first == 91 ? 93 : first
                i += 1; closed = false
                while i < source.length {
                    if ch(i) == 92 && driver == .mariaDB { i = min(source.length, i + 2); continue }
                    if ch(i) == end {
                        if ch(i + 1) == end { i += 2; continue }
                        i += 1; closed = true; break
                    }
                    i += 1
                }
            } else if (48...57).contains(first) {
                kind = .number; i += 1
                while (48...57).contains(ch(i)) || ch(i) == 46 { i += 1 }
                if ch(i) == 101 || ch(i) == 69 {
                    i += 1
                    if ch(i) == 43 || ch(i) == 45 { i += 1 }
                    while (48...57).contains(ch(i)) { i += 1 }
                }
            } else if word(first) {
                kind = .word; i += 1
                while i < source.length && word(ch(i)) { i += 1 }
            } else {
                i += 1
                if [33, 60, 62].contains(first), ch(i) == 61 || (first == 60 && ch(i) == 62) { i += 1 }
            }
            let range = NSRange(location: start, length: i - start)
            result.append(Token(text: source.substring(with: range), range: range, kind: kind, closed: closed))
        }
        return result
    }
}
