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
    @FocusState private var editingFilter: UUID?
    private func reload() { Task { await workspace.load(tab) } }
    var body: some View {
        if tab.filterEditorVisible && !tab.filters.isEmpty {
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
                            ForEach(ColumnFilter.Operation.allCases, id: \.self) { Text($0.label) }
                        }.labelsHidden().accessibilityLabel("Filter Operator")
                        if filter.acceptsValue {
                            TextField(filter.operation == .raw ? "SQL predicate" : "Value", text: $filter.value)
                                .accessibilityIdentifier("Filter Value").focused($editingFilter, equals: filter.id).onChange(of: filter.value) { filter.typed = nil }
                                .onSubmit { applyCondition(filter) }
                        }
                        Button("Apply condition", systemImage: tab.appliedFilters.contains(filter) ? "checkmark.circle.fill" : "checkmark.circle") {
                            applyCondition(filter)
                        }.labelStyle(.iconOnly).help("Apply this condition")
                        Button("Remove condition", systemImage: "minus.circle") { removeCondition($filter) }.labelStyle(.iconOnly)
                    }
                }
                HStack {
                    Button("Add Condition") { addFilter() }
                    Button("Unset") { tab.filters = []; tab.appliedFilters = []; tab.filterEditorVisible = false; tab.offset = 0; reload() }
                    Button("Apply Filters") { Task { await workspace.applyFilters(tab) } }.help("Apply all conditions")
                }
            }.padding(7).background(BrowserChrome.panel).onChange(of: editingFilter) {
                if editingFilter != nil { workspace.focusArea = .filter }
                else if workspace.focusArea == .filter { workspace.focusArea = nil }
            }
            .task(id: tab.filterFocusRequest) {
                guard tab.filterFocusRequest != nil else { return }
                await Task.yield()
                editingFilter = tab.filters.first(where: \.acceptsValue)?.id
                tab.filterFocusRequest = nil
            }
            .onDisappear { if workspace.focusArea == .filter { workspace.focusArea = nil } }
        }
    }

    private func applyCondition(_ filter: ColumnFilter) {
        if let index = tab.appliedFilters.firstIndex(where: { $0.id == filter.id }) { tab.appliedFilters[index] = filter }
        else { tab.appliedFilters.append(filter) }
        tab.offset = 0
        reload()
    }

    func removeCondition(_ filter: Binding<ColumnFilter>) {
        // Reading the row binding inside removeAll would read the array while it is being mutated.
        let id = filter.wrappedValue.id
        let applied = tab.appliedFilters.contains { $0.id == id }
        tab.filters.removeAll { $0.id == id }
        if tab.filters.isEmpty { tab.filterEditorVisible = false }
        if applied {
            tab.appliedFilters.removeAll { $0.id == id }
            tab.offset = 0
            reload()
        }
    }

    private func addFilter() {
        if let column = tab.result.columns.first { tab.filters.append(ColumnFilter(column: column, operation: .equals)) }
    }
}
