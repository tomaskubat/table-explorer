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
    var focusChanged: (Bool) -> Void

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
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
        let colorsChanged = context.coordinator.parent.highlighting != highlighting
        context.coordinator.parent = self
        if colorsChanged { context.coordinator.highlight(editor) }
        if editor.string != text { editor.string = text; context.coordinator.highlight(editor) }
        let size = (editor.string as NSString).length
        if NSMaxRange(selection) <= size && selection != editor.selectedRange() { editor.setSelectedRange(selection) }
        if editor.font?.pointSize != CGFloat(fontSize) { editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        private var statements: [NSRange] = []
        private var current: NSRange?
        private static let keywords = "SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER GROUP ORDER BY LIMIT OFFSET INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE VIEW ALTER DROP BEGIN COMMIT ROLLBACK NULL AND OR NOT WITH EXPLAIN SHOW DISTINCT HAVING RETURNING".split(separator: " ").map(String.init)

        init(_ parent: SQLTextEditor) { self.parent = parent }
        private static let tokens = try! NSRegularExpression(pattern: #"(?is)('(?:''|\\.|[^'])*'|"(?:\"\"|\\.|[^"])*"|(?:--[^\n]*|/\*.*?\*/))|\b(SELECT|FROM|WHERE|AS|JOIN|ON|GROUP|ORDER|BY|LIMIT|OFFSET|HAVING|UNION|ALL|NULL|IS|IN|AND|OR|NOT|UPDATE|SET|INSERT|INTO|VALUES|DELETE|CREATE|ALTER|DROP|TABLE|VIEW|BEGIN|COMMIT|ROLLBACK|WITH|EXPLAIN|SHOW)\b"#)
        func highlight(_ editor: NSTextView) {
            guard let layout = editor.layoutManager else { return }
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            (editor.enclosingScrollView?.verticalRulerView as? SQLLineRuler)?.setText(editor.string)
            statements = parent.showActiveStatement ? SQLDocument.statements(in: editor.string, driver: parent.driver).map(\.range) : []
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            current = nil; markStatement(editor)
            guard parent.highlighting else { return }
            for match in Self.tokens.matches(in: editor.string, range: range) {
                layout.addTemporaryAttribute(.foregroundColor, value: match.range(at: 2).location == NSNotFound ? NSColor.systemGreen : .systemBlue, forCharacterRange: match.range)
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
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)), parent.indent > 0 {
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
