import AppKit
import SwiftUI

struct SQLTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var fontSize: Double = 13
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
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if editor.string != text { editor.string = text; context.coordinator.highlight(editor) }
        let size = (editor.string as NSString).length
        if NSMaxRange(selection) <= size && selection != editor.selectedRange() { editor.setSelectedRange(selection) }
        if editor.font?.pointSize != CGFloat(fontSize) { editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLTextEditor
        init(_ parent: SQLTextEditor) { self.parent = parent }
        private static let tokens = try! NSRegularExpression(pattern: #"(?is)('(?:''|\\.|[^'])*'|"(?:\"\"|\\.|[^"])*"|(?:--[^\n]*|/\*.*?\*/))|\b(SELECT|FROM|WHERE|AS|JOIN|ON|GROUP|ORDER|BY|LIMIT|OFFSET|HAVING|UNION|ALL|NULL|IS|IN|AND|OR|NOT|UPDATE|SET|INSERT|INTO|VALUES|DELETE|CREATE|ALTER|DROP|TABLE|VIEW|BEGIN|COMMIT|ROLLBACK|WITH|EXPLAIN|SHOW)\b"#)
        func highlight(_ editor: NSTextView) {
            guard let layout = editor.layoutManager else { return }
            let range = NSRange(location: 0, length: (editor.string as NSString).length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            for match in Self.tokens.matches(in: editor.string, range: range) {
                layout.addTemporaryAttribute(.foregroundColor, value: match.range(at: 2).location == NSNotFound ? NSColor.systemGreen : .systemBlue, forCharacterRange: match.range)
            }
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
        }
    }
}
