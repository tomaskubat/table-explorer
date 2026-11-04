import SwiftUI

struct TableControls: View {
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    private func reload() { Task { await workspace.load(tab) } }

    var body: some View {
        HStack {
            Button("Filters") { tab.toggleFilters() }.help("Show filters (⌘F)")
            Button("Columns") { tab.columnsShown.toggle() }.help("Choose visible columns (⌘⌥F)")
                .popover(isPresented: $tab.columnsShown) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(tab.result.columns, id: \.self) { column in
                                Toggle(column, isOn: Binding(get: { !tab.hiddenColumns.contains(column) }, set: { visible in
                                    if visible { tab.hiddenColumns.remove(column) } else { tab.hiddenColumns.insert(column) }
                                }))
                            }
                            Divider()
                            Button("Show All") { tab.hiddenColumns.removeAll() }
                            Button("Done") { tab.columnsShown = false }.keyboardShortcut(.cancelAction)
                        }.padding(12)
                    }.frame(width: 180, height: min(310, CGFloat(tab.result.columns.count) * 25 + 100))
                }
            Menu("Sort") {
                ForEach(tab.result.columns, id: \.self) { column in
                    Menu(column) {
                        Button("Ascending") { sort(column, descending: false) }
                        Button("Descending") { sort(column, descending: true) }
                    }
                }
                Button("Clear Sort") { tab.sortColumn = nil; reload() }
            }
            Menu("Page Size: \(tab.limit)") {
                ForEach([25, 100, 300, 500, 1000], id: \.self) { size in
                    Button(String(size)) { tab.limit = size; tab.offset = 0; reload() }
                }
            }
        }.controlSize(.small)
        if tab.filterEditorVisible {
            VStack(alignment: .leading) {
                ForEach($tab.filters) { $filter in
                    HStack {
                        Toggle("Enabled", isOn: $filter.enabled).labelsHidden().accessibilityLabel("Enable condition")
                        if filter.operation != .raw {
                            Picker("Column", selection: $filter.column) {
                                ForEach(tab.result.columns, id: \.self) { Text($0) }
                            }.labelsHidden().accessibilityLabel("Filter Column")
                        }
                        Picker("Operator", selection: $filter.operation) {
                            ForEach(ColumnFilter.Operation.allCases, id: \.self) { Text($0.rawValue) }
                        }.labelsHidden().accessibilityLabel("Filter Operator")
                        if filter.operation != .isNull && filter.operation != .notNull {
                            TextField(filter.operation == .raw ? "SQL predicate" : "Value", text: $filter.value)
                                .accessibilityIdentifier("Filter Value").onChange(of: filter.value) { filter.typed = nil }
                        }
                        Button("Remove condition", systemImage: "minus.circle") { tab.filters.removeAll { $0.id == filter.id } }.labelStyle(.iconOnly)
                    }
                }
                HStack {
                    Button("Add Condition") { addFilter() }
                    Button("Unset") { tab.filters = []; tab.appliedFilters = []; tab.offset = 0; reload() }
                    Button("Apply Filters") { tab.appliedFilters = tab.filters; tab.offset = 0; reload() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
    }

    private func addFilter() {
        if let column = tab.result.columns.first { tab.filters.append(ColumnFilter(column: column)) }
    }
    private func sort(_ column: String, descending: Bool) {
        tab.sortColumn = column; tab.descending = descending; tab.offset = 0; reload()
    }
}
