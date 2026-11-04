import SwiftUI

struct TableControls: View {
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    private func reload() { Task { await workspace.load(tab) } }

    var body: some View {
        HStack {
            Button("Columns") { tab.columnsShown.toggle() }.help("Choose visible columns")
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
            Button("Filters") { tab.toggleFilters() }.help("Show filters")
        }.controlSize(.small)
    }
}

struct FilterConditions: View {
    let workspace: Workspace
    @Bindable var tab: WorkspaceTab
    @FocusState private var editingFilter: Bool
    private func reload() { Task { await workspace.load(tab) } }
    var body: some View {
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
                                .accessibilityIdentifier("Filter Value").focused($editingFilter).onChange(of: filter.value) { filter.typed = nil }
                        }
                        Button("Apply condition", systemImage: tab.appliedFilters.contains(filter) ? "checkmark.circle.fill" : "checkmark.circle") {
                            if let index = tab.appliedFilters.firstIndex(where: { $0.id == filter.id }) { tab.appliedFilters[index] = filter }
                            else { tab.appliedFilters.append(filter) }
                            tab.offset = 0; reload()
                        }.labelStyle(.iconOnly).help("Apply this condition")
                        Button("Remove condition", systemImage: "minus.circle") { tab.filters.removeAll { $0.id == filter.id } }.labelStyle(.iconOnly)
                    }
                }
                HStack {
                    Button("Add Condition") { addFilter() }
                    Button("Unset") { tab.filters = []; tab.appliedFilters = []; tab.offset = 0; reload() }
                    Button("Apply Filters") { Task { await workspace.applyFilters(tab) } }.help("Apply all conditions")
                }
            }.padding(7).background(BrowserChrome.panel).onChange(of: editingFilter) {
                if editingFilter { workspace.focusArea = .filter }
                else if workspace.focusArea == .filter { workspace.focusArea = nil }
            }
        }
    }

    private func addFilter() {
        if let column = tab.result.columns.first { tab.filters.append(ColumnFilter(column: column)) }
    }
}
