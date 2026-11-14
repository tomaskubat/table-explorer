import AppKit
import SwiftUI

struct RawSQLFilterField: NSViewRepresentable {
    @Binding var text: String
    let columns: [ColumnInfo]
    let driver: DatabaseDriver
    let focusRequest: UUID?
    let didFocus: () -> Void
    let focusChanged: (Bool) -> Void
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "SQL predicate"
        field.bezelStyle = .roundedBezel; field.controlSize = .small
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.usesSingleLineMode = true; field.lineBreakMode = .byClipping
        field.isAutomaticTextCompletionEnabled = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("Filter Value"); field.setAccessibilityLabel("SQL predicate")
        field.toolTip = "Choose a suggestion with ↑/↓ and Tab or Return. Escape closes suggestions."
        field.delegate = context.coordinator
        context.coordinator.field = field
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)),
                                               name: NSTextView.didChangeSelectionNotification, object: nil)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // The field editor owns text during editing. Older SwiftUI renders may
        // otherwise overwrite a just-accepted completion before the next key.
        if field.currentEditor() == nil && field.stringValue != text { field.stringValue = text; coordinator.closeSuggestions() }
        if let focusRequest, coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field, weak coordinator] in
                guard let field, let window = field.window, let coordinator else { return }
                window.makeFirstResponder(field)
                coordinator.parent.didFocus()
            }
        }
    }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        field.delegate = nil
        coordinator.closeSuggestions()
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RawSQLFilterField
        weak var field: NSTextField?
        var lastFocusRequest: UUID?
        private var panel: SuggestionPanel?
        private var candidates: [SQLFilterCompletion] = []
        private var selected = 0
        private var replacing = false
        private var suppressed = false
        init(_ parent: RawSQLFilterField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let editor = field?.currentEditor() as? NSTextView else { return }
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            parent.focusChanged(true)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            closeSuggestions(); parent.focusChanged(false)
        }
        func controlTextDidChange(_ notification: Notification) {
            guard !replacing, let field else { return }
            parent.text = field.stringValue
            suppressed = false
            updateSuggestions()
        }
        @objc func selectionChanged(_ notification: Notification) {
            guard !replacing, !suppressed, let editor = field?.currentEditor() as? NSTextView,
                  notification.object as? NSTextView === editor else { return }
            updateSuggestions()
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                let direction = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
                if candidates.isEmpty { suppressed = false; updateSuggestions(explicit: true) }
                else { selected = (selected + direction + candidates.count) % candidates.count; renderSuggestions() }
                return !candidates.isEmpty
            case #selector(NSResponder.insertTab(_:)):
                guard !candidates.isEmpty else { return false }
                accept(selected); return true
            case #selector(NSResponder.insertNewline(_:)):
                if candidates.isEmpty { parent.submit() } else { accept(selected) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                suppressed = true; closeSuggestions(); return true
            case #selector(NSResponder.complete(_:)):
                suppressed = false; updateSuggestions(explicit: true); return true
            default: return false
            }
        }
        private func updateSuggestions(explicit: Bool = false) {
            guard !suppressed, let editor = field?.currentEditor() as? NSTextView, !editor.hasMarkedText() else { closeSuggestions(); return }
            let next = SQLFilterCompleter.suggestions(in: editor.string, selection: editor.selectedRange(),
                                                      columns: parent.columns, driver: parent.driver, explicit: explicit)
            guard !next.isEmpty else { closeSuggestions(); return }
            if next != candidates { candidates = next; selected = 0 }
            renderSuggestions()
        }
        private func accept(_ index: Int) {
            guard candidates.indices.contains(index), let editor = field?.currentEditor() as? NSTextView else { return }
            let candidate = candidates[index]
            guard NSMaxRange(candidate.range) <= (editor.string as NSString).length else { closeSuggestions(); return }
            let completed = candidate.applying(to: editor.string)
            replacing = true
            editor.insertText(candidate.insertion, replacementRange: candidate.range)
            editor.setSelectedRange(completed.selection)
            parent.text = editor.string
            replacing = false
            closeSuggestions()
            updateSuggestions(explicit: true)
        }
        func closeSuggestions() {
            candidates = []
            panel?.orderOut(nil)
            if let panel { panel.parent?.removeChildWindow(panel) }
        }
        private func renderSuggestions() {
            guard let field, let window = field.window else { return }
            let popup = panel ?? SuggestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel = popup
            let width = FilterSuggestionStyle.width(for: candidates)
            let height = CGFloat(min(candidates.count, 8)) * FilterSuggestionStyle.rowHeight + FilterSuggestionStyle.inset * 2
            popup.contentView = NSHostingView(rootView: FilterSuggestionList(items: candidates, selected: selected) { [weak self] index in self?.accept(index) })
            popup.hasShadow = true; popup.isOpaque = false; popup.backgroundColor = .clear
            popup.level = .popUpMenu; popup.hidesOnDeactivate = true
            popup.title = "SQL Filter Suggestions"
            let anchor = window.convertToScreen(field.convert(field.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -1000, dy: -1000)
            let origin = NSPoint(x: min(max(anchor.minX, screen.minX), screen.maxX - width),
                                 y: anchor.minY - height - 3 < screen.minY ? anchor.maxY + 3 : anchor.minY - height - 3)
            popup.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            if popup.parent == nil { window.addChildWindow(popup, ordered: .above) }
            popup.orderFront(nil)
        }
    }
}

private final class SuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private enum FilterSuggestionStyle {
    static let rowHeight: CGFloat = 22
    static let inset: CGFloat = 3

    static func width(for items: [SQLFilterCompletion]) -> CGFloat {
        let titleFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let detailFont = NSFont.systemFont(ofSize: 10)
        let content = items.map { item in
            (item.title as NSString).size(withAttributes: [.font: titleFont]).width
                + min(100, (item.detail as NSString).size(withAttributes: [.font: detailFont]).width)
        }.max() ?? 0
        return min(320, max(190, ceil(content) + 26))
    }
}

private struct FilterSuggestionList: View {
    let items: [SQLFilterCompletion]
    let selected: Int
    let accept: (Int) -> Void
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Button { accept(index) } label: {
                            HStack(spacing: 8) {
                                Text(item.title).font(.system(size: 11, design: .monospaced)).lineLimit(1).layoutPriority(1)
                                Spacer(minLength: 4)
                                Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.horizontal, 6).frame(height: FilterSuggestionStyle.rowHeight).frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .background(index == selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 3))
                        }.buttonStyle(.plain).id(index).accessibilityLabel("Complete " + item.title)
                            .help(item.detail.isEmpty ? item.title : item.title + " · " + item.detail)
                    }
                }.padding(FilterSuggestionStyle.inset)
            }.onChange(of: selected, initial: true) { proxy.scrollTo(selected) }
        }.background(BrowserChrome.paper, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(BrowserChrome.line, lineWidth: 0.7).allowsHitTesting(false) }
    }
}
