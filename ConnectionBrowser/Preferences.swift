import CryptoKit
import SwiftUI

enum BrowserPreferences {
    // UserDefaults is thread-safe. Connection workers also read timeout values.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        if let path = ProcessInfo.processInfo.environment["CONNECTION_BROWSER_LIBRARY"] {
            let suffix = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return UserDefaults(suiteName: "local.connectionbrowser.library." + suffix)!
        }
        return .standard
    }()
    static func integer(_ key: String, fallback: Int, range: ClosedRange<Int>) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return min(range.upperBound, max(range.lowerBound, defaults.integer(forKey: key)))
    }
    static var pageSize: Int { integer("pageSize", fallback: 300, range: 1...10000) }
    static var queryLimit: Int { integer("queryLimit", fallback: 1000, range: 1...100000) }
    static var timeout: Int { integer("connectTimeout", fallback: 5, range: 1...120) }
    static var busyTimeout: Int { integer("sqliteBusySeconds", fallback: 3, range: 0...60) }
}

struct BrowserAppearance: ViewModifier {
    @AppStorage("theme", store: BrowserPreferences.defaults) private var theme = "System"
    func body(content: Content) -> some View {
        content.preferredColorScheme(theme == "System" ? nil : theme == "Dark" ? .dark : .light)
    }
}

struct PreferencesView: View {
    let library: ConnectionLibrary
    @AppStorage("pageSize", store: BrowserPreferences.defaults) private var pageSize = 300
    @AppStorage("queryLimit", store: BrowserPreferences.defaults) private var queryLimit = 1000
    @AppStorage("connectTimeout", store: BrowserPreferences.defaults) private var timeout = 5
    @AppStorage("sqliteBusySeconds", store: BrowserPreferences.defaults) private var busy = 3
    @AppStorage("theme", store: BrowserPreferences.defaults) private var theme = "System"
    @AppStorage("queryFontSize", store: BrowserPreferences.defaults) private var font = 13.0
    @AppStorage("gridFontSize", store: BrowserPreferences.defaults) private var gridFont = 12.0
    @AppStorage("highlightSQL", store: BrowserPreferences.defaults) private var highlight = true
    @AppStorage("indentSpaces", store: BrowserPreferences.defaults) private var indent = 4
    @AppStorage("csvSeparator", store: BrowserPreferences.defaults) private var separator = ","
    @AppStorage("csvHeader", store: BrowserPreferences.defaults) private var header = true
    @AppStorage("csvNull", store: BrowserPreferences.defaults) private var nullToken = "\\N"
    @AppStorage("querySafety", store: BrowserPreferences.defaults) private var safety = "Review writes"
    @AppStorage("dumpTool", store: BrowserPreferences.defaults) private var dumpTool = ""
    @AppStorage("restoreTool", store: BrowserPreferences.defaults) private var restoreTool = ""
    @State private var locationError: String?
    var body: some View {
        TabView {
            Form {
                Picker("Rows per new table page", selection: $pageSize) { ForEach([25, 100, 300, 500, 1000], id: \.self) { Text(String($0)) } }
                    .accessibilityIdentifier("Default Page Size")
                Stepper("SQL result limit: \(queryLimit) rows", value: $queryLimit, in: 100...100000, step: 100)
                Stepper("Connection timeout: \(timeout) seconds", value: $timeout, in: 1...120)
                Stepper("SQLite lock wait: \(busy) seconds", value: $busy, in: 0...60)
                Divider()
                Picker("Default CSV delimiter", selection: $separator) { Text("Comma").tag(","); Text("Semicolon").tag(";"); Text("Tab").tag("\t") }
                Toggle("Include CSV header", isOn: $header)
                TextField("CSV NULL token", text: $nullToken)
            }.tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Picker("Appearance", selection: $theme) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                Stepper("Editor font: \(Int(font)) pt", value: $font, in: 9...28)
                Stepper("Data grid font: \(Int(gridFont)) pt", value: $gridFont, in: 9...24)
                Toggle("Highlight SQL syntax", isOn: $highlight)
                Picker("Tab indentation", selection: $indent) { Text("Tab character").tag(0); Text("2 spaces").tag(2); Text("4 spaces").tag(4); Text("8 spaces").tag(8) }
            }.tabItem { Label("Appearance", systemImage: "textformat") }
            Form {
                LabeledContent("Connection library") { Text(library.directory.path).textSelection(.enabled) }
                HStack {
                    Button("Reveal Folder") { NSWorkspace.shared.open(library.directory) }
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let folder = panel.url { changeLocation(folder) }
                    }
                    Button("Use Default Folder") { changeLocation(URL.applicationSupportDirectory.appending(path: "ConnectionBrowser")) }
                }
                if ProcessInfo.processInfo.environment["CONNECTION_BROWSER_LIBRARY"] != nil {
                    Text("The launch environment selects the initial library folder.").font(.caption)
                }
                Text("Choosing a folder opens its profiles and query history. An empty folder starts a new library.").font(.caption)
                if let locationError { Text(locationError).foregroundStyle(.red) }
                Divider()
                TextField("Dump tool (automatic if empty)", text: $dumpTool)
                TextField("Restore tool (automatic if empty)", text: $restoreTool)
            }.tabItem { Label("Locations", systemImage: "folder") }
            Form {
                Picker("Direct SQL execution", selection: $safety) {
                    ForEach(["Review writes", "Review every statement", "Run immediately"], id: \.self) { Text($0) }
                }.accessibilityIdentifier("SQL Safety")
                Text("Production profiles always review direct SQL. Table edits are staged until you commit the preview. Saved passwords use the macOS Keychain.").font(.callout)
            }.tabItem { Label("Security", systemImage: "lock") }
            Grid(alignment: .leading, horizontalSpacing: 25, verticalSpacing: 7) {
                ForEach(Self.keys, id: \.0) { name, binding, scope in
                    GridRow { Text(name); Text(binding).monospaced(); Text(scope).foregroundStyle(.secondary) }
                }
            }.tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }.padding(18).frame(width: 590, height: 345).modifier(BrowserAppearance())
    }
    private static let keys = [
        ("Saved Connections", "⌘N", "Application"), ("New Query", "⌘T", "Workspace"),
        ("Open Anything", "⌘P", "Workspace"), ("SQL Console", "⇧⌘C", "Workspace"),
        ("Add Row", "⌘I", "Data grid"), ("Duplicate Rows", "⌘D", "Data grid"),
        ("Row Detail", "Space", "Data grid"), ("Run Current", "⌘Return", "SQL editor"),
        ("Toggle Line Comment", "⌘/", "SQL editor"), ("Complete SQL", "⌥Esc", "SQL editor"),
        ("Filters / Columns", "⌘F / ⌘⌥F", "Data grid"), ("Page back / forward", "⌘← / ⌘→", "Data grid"),
        ("Preview changes", "⇧⌘P", "Data tab"), ("Save / Commit", "⌘S", "Active tab")
    ]
    private func changeLocation(_ folder: URL) {
        do { try library.useDirectory(folder); locationError = nil }
        catch { locationError = error.localizedDescription }
    }
}
