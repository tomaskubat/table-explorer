import SwiftUI

struct CellEdit: Identifiable {
    let id = UUID()
    let column: String
    let value: SQLValue
    let draft: RowChange?
    let writable: Bool
    let nullable: Bool
}

struct CellEditor: View {
    let target: CellEdit
    let tab: WorkspaceTab
    @State private var text: String
    @State private var isNull: Bool
    @Environment(\.dismiss) private var dismiss
    init(target: CellEdit, tab: WorkspaceTab) {
        self.target = target; self.tab = tab
        _isNull = State(initialValue: target.value == .null)
        _text = State(initialValue: target.value == .null ? "" : target.value.display)
    }
    private var editable: Bool {
        if case .blob = target.value { return false }
        return target.writable
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tab.title + " / " + target.column).font(.headline)
            if target.nullable { Toggle("NULL", isOn: $isNull).disabled(!editable) }
            if editable {
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).disabled(isNull).accessibilityIdentifier("Cell Value")
            } else {
                ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            HStack {
                Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if editable {
                    Button("Stage Value") {
                        guard var draft = target.draft else { return }
                        draft.defaults.remove(target.column)
                        let value: SQLValue = isNull ? .null : .text(text)
                        if draft.original?[target.column] == value { draft.changes.removeValue(forKey: target.column) }
                        else { draft.changes[target.column] = value }
                        tab.stage(draft); dismiss()
                    }
                }
            }
        }.padding(16).frame(width: 500, height: 320)
    }
}
