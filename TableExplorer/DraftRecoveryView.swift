import SwiftUI

struct PanelLayout: Codable, Equatable {
    var items = true
    var detail = true
    var console = true
}

struct RecoverableSQL: Identifiable, Codable {
    let id: UUID
    let database: String
    let title: String
    let sql: String
    let date: Date
}

struct DraftRecoveryView: View {
    let workspace: Workspace
    @State private var selected: UUID?
    @Environment(\.dismiss) private var dismiss
    private var drafts: [RecoverableSQL] { workspace.notebook.availableDrafts(in: workspace.database) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recover SQL Draft").font(.title2)
            Text(workspace.profile.name + " / " + workspace.database)
            Text("Open a local copy of the SQL text in this session. Review it before running.").font(.caption)
            if drafts.isEmpty {
                ContentUnavailableView("No Recoverable Drafts", systemImage: "doc.text")
            } else {
                List(drafts, selection: $selected) { draft in
                    VStack(alignment: .leading) {
                        HStack { Text(draft.title).bold(); Spacer(); Text(draft.date, format: .dateTime).font(.caption) }
                        Text(draft.sql).font(.system(.caption, design: .monospaced)).lineLimit(2)
                    }.tag(draft.id)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Recover Text") {
                    if let draft = drafts.first(where: { $0.id == selected }) { workspace.recover(draft); dismiss() }
                }.disabled(selected == nil)
            }
        }.padding(18).frame(width: 480, height: 300)
        .onAppear { selected = drafts.first?.id }
    }
}
