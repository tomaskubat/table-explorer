import AppKit
import SwiftUI

struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var fontSize: Double = 13
    var highlighting = true
    var indent = 4
    var driver: DatabaseDriver = .mariaDB
    var objectNames: [String] = []
    var showActiveStatement = true
    @AppStorage("editorFont", store: BrowserPreferences.defaults) private var family = "System Mono"
    @AppStorage("customInks", store: BrowserPreferences.defaults) private var inks = Data()
    var focusChanged: (Bool) -> Void

    init(text: Binding<String>, selection: Binding<NSRange>, fontSize: Double = 13, highlighting: Bool = true, indent: Int = 4,
         driver: DatabaseDriver = .mariaDB, objectNames: [String] = [], showActiveStatement: Bool = true, focusChanged: @escaping (Bool) -> Void) {
        _text = text; _selection = selection; self.fontSize = fontSize; self.highlighting = highlighting; self.indent = indent
        self.driver = driver; self.objectNames = objectNames; self.showActiveStatement = showActiveStatement; self.focusChanged = focusChanged
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.font = FontChoice.font(family, fontSize)
        editor.textContainerInset = NSSize(width: 5, height: 6)
        editor.setAccessibilityLabel("SQL Editor")
        editor.setAccessibilityIdentifier("SQL Editor")
        editor.string = text
        editor.delegate = context.coordinator
        let ruler = SQLLineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.clientView = editor
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        context.coordinator.highlight(editor)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let colorsChanged = context.coordinator.parent.highlighting != highlighting || context.coordinator.paletteData != inks
        context.coordinator.paletteData = inks
        context.coordinator.parent = self
        if colorsChanged { context.coordinator.highlight(editor) }
        if editor.string != text { editor.string = text; context.coordinator.highlight(editor) }
        let size = (editor.string as NSString).length
        if NSMaxRange(selection) <= size && selection != editor.selectedRange() { editor.setSelectedRange(selection) }
        let font = FontChoice.font(family, fontSize)
        if editor.font != font { editor.font = font }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        var paletteData = Data()
        private var replacing = false
        private var statements: [NSRange] = []
        private var current: NSRange?
        private static let keywords = "SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER GROUP ORDER BY LIMIT OFFSET INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE VIEW ALTER DROP BEGIN COMMIT ROLLBACK NULL AND OR NOT WITH EXPLAIN SHOW DISTINCT HAVING RETURNING".split(separator: " ").map(String.init)

        init(_ parent: SQLTextEditor) { self.parent = parent }

        func highlight(_ editor: NSTextView) {
            guard let layout = editor.layoutManager else { return }
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            (editor.enclosingScrollView?.verticalRulerView as? SQLLineRuler)?.setText(editor.string)
            statements = parent.showActiveStatement ? SQLDocument.statements(in: editor.string, driver: parent.driver).map(\.range) : []
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            current = nil; markStatement(editor)
            guard parent.highlighting else { return }
            let palette = InkPalette(parent.inks)
            for match in SQLSyntax.tokens.matches(in: editor.string, range: range) {
                layout.addTemporaryAttribute(.foregroundColor, value: SQLSyntax.ink(for: match, in: editor.string, palette: palette), forCharacterRange: match.range)
            }
        }
        func markStatement(_ editor: NSTextView) {
            let range = statements.first { editor.selectedRange().location <= NSMaxRange($0) } ?? statements.last
            guard range != current, let layout = editor.layoutManager else { return }
            let length = (editor.string as NSString).length
            if let current, NSMaxRange(current) <= length { layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: current) }
            current = range
            if let range, NSMaxRange(range) <= length {
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.08), forCharacterRange: range)
            }
        }
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange range: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let prefix = (textView.string as NSString).substring(with: range).lowercased()
            return Set(Self.keywords + parent.objectNames).filter { $0.lowercased().hasPrefix(prefix) }.sorted()
        }
        private func replace(in editor: NSTextView, range: NSRange, with text: String, selection: NSRange? = nil) {
            replacing = true
            editor.insertText(text, replacementRange: range)
            if let selection { editor.setSelectedRange(selection) }
            replacing = false
        }

        func textView(_ view: NSTextView, shouldChangeTextIn range: NSRange, replacementString input: String?) -> Bool {
            guard !replacing, let input, input.count == 1, NSApp.currentEvent?.type == .keyDown,
                  NSApp.currentEvent?.modifierFlags.contains(.command) == false, !view.hasMarkedText() else { return true }
            let source = view.string as NSString
            guard range.location != NSNotFound, NSMaxRange(range) <= source.length else { return true }
            let prefs = BrowserPreferences.defaults
            let pairs = prefs.bool(forKey: "autoPairs")
            let uppercase = prefs.bool(forKey: "uppercaseKeywords")
            guard pairs || uppercase else { return true }
            if pairs, range.length == 0, range.location < source.length, [")","]","}","'", "\"","`"].contains(input),
               source.substring(with: NSRange(location: range.location, length: 1)) == input {
                view.setSelectedRange(NSRange(location: range.location + 1, length: 0)); return false
            }
            let before = source.substring(to: range.location)
            guard SQLTyping.isCode(before, driver: parent.driver) else { return true }
            if pairs, let end = ["(":")", "[":"]", "{":"}", "'":"'", "\"":"\"", "`":"`"][input] {
                replace(in: view, range: range, with: input + source.substring(with: range) + end,
                        selection: NSRange(location: range.location + 1, length: range.length))
                return false
            }
            if uppercase, range.length == 0, !SQLTyping.word(input.first!), let word = SQLTyping.lastWord(before),
               Self.keywords.contains(word.uppercased()), word != word.uppercased() {
                let n = word.utf16.count
                replace(in: view, range: NSRange(location: range.location - n, length: n), with: word.uppercased() + input)
                return false
            }
            return true
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let isTab = selector == #selector(NSResponder.insertTab(_:)), isReturn = selector == #selector(NSResponder.insertNewline(_:))
            let completion = BrowserPreferences.defaults.string(forKey: "completionKey")
            if (isTab && ["Tab","Return or Tab"].contains(completion ?? "")) || (isReturn && ["Return","Return or Tab"].contains(completion ?? "")) {
                let selection = textView.selectedRange()
                let before = (textView.string as NSString).substring(to: selection.location)
                if selection.length == 0, let prefix = SQLTyping.lastWord(before), prefix.count >= 2, SQLTyping.isCode(before, driver: parent.driver) {
                    let matches = Set(Self.keywords + parent.objectNames).filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
                    if matches.count == 1, let match = matches.first, match.caseInsensitiveCompare(prefix) != .orderedSame {
                        replace(in: textView, range: NSRange(location: selection.location - prefix.utf16.count, length: prefix.utf16.count), with: match)
                        return true
                    }
                }
            }
            if isTab, parent.indent > 0 {
                textView.insertText(String(repeating: " ", count: parent.indent), replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
        func textDidBeginEditing(_ notification: Notification) { parent.focusChanged(true) }
        func textDidEndEditing(_ notification: Notification) { parent.focusChanged(false) }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            parent.selection = editor.selectedRange()
            parent.focusChanged(true)
            highlight(editor)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, parent.selection != editor.selectedRange() else { return }
            parent.selection = editor.selectedRange()
            markStatement(editor)
        }
    }
}

enum SQLSyntax {
    static let tokens = try! NSRegularExpression(pattern: #"(?is)('(?:''|\\.|[^'])*'|"(?:""|\\.|[^"])*"|`(?:``|[^`])*`|(?:--[^\n]*|/\*.*?\*/))|\b(SELECT|FROM|WHERE|AS|JOIN|ON|GROUP|ORDER|BY|LIMIT|OFFSET|HAVING|UNION|ALL|NULL|IS|IN|AND|OR|NOT|UPDATE|SET|INSERT|INTO|VALUES|DELETE|CREATE|ALTER|DROP|TABLE|VIEW|BEGIN|COMMIT|ROLLBACK|WITH|EXPLAIN|SHOW)\b|\b\d+(?:\.\d+)?\b"#)
    static func ink(for token: NSTextCheckingResult, in sql: String, palette: InkPalette) -> NSColor {
        if token.range(at: 2).location != NSNotFound { return palette.color(.keyword) }
        switch (sql as NSString).character(at: token.range.location) {
        case 45,47: return palette.color(.comment)
        case 39: return palette.color(.string)
        case 34: return palette.color(.quoted)
        case 96: return palette.color(.identifier)
        default: return palette.color(.number)
        }
    }

    static func colored(_ sql: String) -> AttributedString {
        let palette = InkPalette(BrowserPreferences.defaults.data(forKey: "customInks") ?? Data())
        var text = AttributedString(sql)
        for token in tokens.matches(in: sql, range: NSRange(sql.startIndex..., in: sql)) {
            guard let range = Range(token.range, in: sql), let colorRange = Range(range, in: text) else { continue }
            text[colorRange].foregroundColor = Color(nsColor: ink(for: token, in: sql, palette: palette))
        }
        return text
    }
}

private enum SQLTyping {
    static func word(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
    static func lastWord(_ text: String) -> String? {
        let start = text.lastIndex(where: { !word($0) }).map { text.index(after: $0) } ?? text.startIndex
        return start == text.endIndex ? nil : String(text[start...])
    }
    static func isCode(_ prefix: String, driver: DatabaseDriver) -> Bool {
        var quote: Character?, line = false, block = false, i = prefix.startIndex
        while i != prefix.endIndex {
            let c = prefix[i]; i = prefix.index(after: i)
            let next = i == prefix.endIndex ? nil : prefix[i]
            if line { if c.isNewline { line = false }; continue }
            if block { if c == "*", next == "/" { block = false; i = prefix.index(after: i) }; continue }
            if let q = quote {
                if c == "\\", driver == .mariaDB, next != nil { i = prefix.index(after: i); continue }
                if q == c {
                    if next == q { i = prefix.index(after: i) } else { quote = nil }
                }
            } else if c == "-", next == "-" { line = true }
            else if c == "#", driver == .mariaDB { line = true }
            else if c == "/", next == "*" { block = true; i = prefix.index(after: i) }
            else if c == "'" || c == "\"" || c == Character(UnicodeScalar(96)) { quote = c }
            else if c == "[", driver == .sqlite { quote = "]" }
        }
        return quote == nil && !line && !block
    }
}
