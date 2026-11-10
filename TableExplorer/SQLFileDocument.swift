import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let connectionSQL = UTType(importedAs: "org.iso.sql", conformingTo: .plainText)
}

struct SQLFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.connectionSQL] }
    var text = ""
    init(text: String = "") { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = try Self.decode(data)
    }
    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xef, 0xbb, 0xbf]), let utf8 = String(data: data.dropFirst(3), encoding: .utf8) { return utf8 }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]), let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        else { throw BrowserError("Open a UTF-8 or UTF-16 SQL document.") }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

struct SQLFileView: View {
    @Binding var file: SQLFileDocument
    let registry: WorkspaceRegistry
    @Environment(\.openWindow) private var openWindow
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var target: UUID?
    @AppStorage("queryFontSize", store: BrowserPreferences.defaults) private var font = 13.0
    @AppStorage("highlightSQL", store: BrowserPreferences.defaults) private var highlight = true
    @AppStorage("indentSpaces", store: BrowserPreferences.defaults) private var indent = 4
    var body: some View {
        VStack(alignment: .leading) {
            SQLTextEditor(text: $file.text, selection: $selection, fontSize: font, highlighting: highlight, indent: indent) { _ in }
            HStack {
                Picker("Workspace", selection: $target) {
                    Text("Choose a connection").tag(nil as UUID?)
                    ForEach(registry.sessions.values.filter(\.connected).sorted { $0.profile.name < $1.profile.name }) { workspace in
                        Text(workspace.profile.name + " / " + workspace.database).tag(Optional(workspace.id))
                    }
                }
                Button("Open in Workspace") {
                    if let target, let workspace = registry.sessions[target] {
                        workspace.newQuery(text: file.text)
                        registry.activate(target); openWindow(id: "workspace")
                    }
                }.disabled(target.flatMap { registry.sessions[$0] }?.connected != true)
                Button("Saved Connections") { openWindow(id: "connections") }
            }
        }.padding(10).frame(minWidth: 520, minHeight: 320).modifier(BrowserAppearance())
    }
}
