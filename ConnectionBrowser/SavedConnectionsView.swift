import SwiftUI

private struct SavedConnection: Identifiable {
    let id: String
    let name: String
    let detail: String
    let environment: String
}

private struct ConnectionGroup: Identifiable {
    let name: String
    let connections: [SavedConnection]
    var id: String { name }

    static let examples = [
        ConnectionGroup(name: "Catalog", connections: [
            SavedConnection(id: "catalog-local", name: "catalog@local", detail: "127.0.0.1 · catalog", environment: "loc"),
            SavedConnection(id: "catalog-stage", name: "catalog@stage", detail: "SSH · catalog_stage", environment: "sta")
        ]),
        ConnectionGroup(name: "Warehouse", connections: [
            SavedConnection(id: "warehouse-local", name: "warehouse@local", detail: "127.0.0.1 · warehouse", environment: "loc")
        ])
    ]
}

struct SavedConnectionsView: View {
    @State private var selection: SavedConnection.ID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Connection Browser")
                    .font(.system(size: 24, weight: .light))
                Text("Saved connections")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            List(selection: $selection) {
                ForEach(ConnectionGroup.examples) { group in
                    ConnectionGroupSection(group: group)
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, 32)
        }
        .frame(minWidth: 520, minHeight: 290)
    }
}

private struct ConnectionGroupSection: View {
    let group: ConnectionGroup
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.connections) { connection in
                ConnectionRow(connection: connection)
                    .tag(connection.id)
                    .listRowSeparator(.hidden)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "powerplug.fill")
                    .frame(width: 26, height: 26)
                    .overlay { Circle().strokeBorder(lineWidth: 1.4) }
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(group.name).font(.headline)
            }
            .frame(height: 32)
        }
        .listRowSeparator(.hidden)
    }
}

private struct ConnectionRow: View {
    let connection: SavedConnection

    var body: some View {
        HStack(spacing: 9) {
            Text("Mr")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color(red: 0.12, green: 0.54, blue: 0.57), in: Circle())
                .accessibilityLabel("MariaDB")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(connection.name)
                    Text(connection.environment)
                        .font(.caption2)
                        .padding(.horizontal, 3)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(lineWidth: 0.8)
                        }
                        .foregroundStyle(connection.environment == "loc" ? Color.green : .orange)
                }
                Text(connection.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 33)
    }
}
