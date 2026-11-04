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
    static func folder(_ key: String, fallback: URL) -> URL {
        guard let path = defaults.string(forKey: key), path.hasPrefix("/") else { return fallback }
        return URL(filePath: path)
    }
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
    @AppStorage("gridFontSize", store: BrowserPreferences.defaults) private var gridFont = 14.0
    @AppStorage("highlightSQL", store: BrowserPreferences.defaults) private var highlight = true
    @AppStorage("indentSpaces", store: BrowserPreferences.defaults) private var indent = 4
    @AppStorage("csvSeparator", store: BrowserPreferences.defaults) private var separator = ","
    @AppStorage("csvHeader", store: BrowserPreferences.defaults) private var header = true
    @AppStorage("csvNull", store: BrowserPreferences.defaults) private var nullToken = "\\N"
    @AppStorage("querySafety", store: BrowserPreferences.defaults) private var safety = "Review writes"
    @AppStorage("dumpTool", store: BrowserPreferences.defaults) private var dumpTool = ""
    @AppStorage("restoreTool", store: BrowserPreferences.defaults) private var restoreTool = ""
    @AppStorage("reopenWorkspaces", store: BrowserPreferences.defaults) private var reopen = false
    @AppStorage("loadingWallpaper", store: BrowserPreferences.defaults) private var wallpaper = true
    @AppStorage("autoHideScrollers", store: BrowserPreferences.defaults) private var hideScrollers = true
    @AppStorage("alternateRows", store: BrowserPreferences.defaults) private var alternate = true
    @AppStorage("expandCells", store: BrowserPreferences.defaults) private var expand = false
    @AppStorage("keepAlive", store: BrowserPreferences.defaults) private var keepAlive = true
    @AppStorage("statementTimeout", store: BrowserPreferences.defaults) private var statementTimeout = 0
    @AppStorage("estimateThreshold", store: BrowserPreferences.defaults) private var estimateThreshold = 500000
    @AppStorage("estimateRows", store: BrowserPreferences.defaults) private var estimate = false
    @AppStorage("autoSaveDrafts", store: BrowserPreferences.defaults) private var drafts = true
    @AppStorage("autoPairs", store: BrowserPreferences.defaults) private var pairs = false
    @AppStorage("uppercaseKeywords", store: BrowserPreferences.defaults) private var uppercase = false
    @AppStorage("completionKey", store: BrowserPreferences.defaults) private var completion = "Explicit shortcut"
    @AppStorage("csvLineEnding", store: BrowserPreferences.defaults) private var ending = "LF"
    @AppStorage("csvQuoteAll", store: BrowserPreferences.defaults) private var quoteAll = false
    @AppStorage("csvDecimalComma", store: BrowserPreferences.defaults) private var decimal = false
    @State private var locationError: String?
    var updateChecks: Binding<Bool>?
    var body: some View {
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Application") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Reopen closed workspaces at startup", isOn: $reopen)
                                .onChange(of: reopen) { if !reopen { BrowserPreferences.defaults.removeObject(forKey: "startupLibraries") } }
                            Text("Reconnect to the profiles that were open when you quit. Each connection controls whether its tabs are restored.").font(.caption).foregroundStyle(.secondary)
                            Toggle("Show loading artwork", isOn: $wallpaper)
                            if let updateChecks { Toggle("Automatically check for updates", isOn: updateChecks) }
                        }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        GroupBox("Table Data") {
                            VStack(alignment: .leading, spacing: 7) {
                                Picker("Rows per page", selection: $pageSize) {
                                    ForEach([25, 100, 300, 500, 1000], id: \.self) { Text(String($0)) }
                                }.accessibilityIdentifier("Default Page Size")
                                Stepper("SQL result limit: \(queryLimit)", value: $queryLimit, in: 100...100000, step: 100)
                                Toggle("Auto hide table scrollers", isOn: $hideScrollers)
                                Toggle("Alternating row background colors", isOn: $alternate)
                                Toggle("Show tooltips for truncated cells", isOn: $expand)
                                Toggle("Estimate large MariaDB table counts", isOn: $estimate)
                                HStack { Text("Above"); TextField("Estimate threshold", value: $estimateThreshold, format: .number).frame(width: 85); Text("rows") }.disabled(!estimate)
                            }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        GroupBox("Connections") {
                            VStack(alignment: .leading, spacing: 7) {
                                Stepper("Connection timeout: \(timeout) s", value: $timeout, in: 1...120)
                                Stepper("SQLite lock wait: \(busy) s", value: $busy, in: 0...60)
                                HStack { Text("SQL timeout"); TextField("Query timeout", value: $statementTimeout, format: .number).frame(width: 65); Text("s") }
                                Text("0 allows SQL to run without a time limit.").font(.caption)
                                Toggle("Keep MariaDB connections alive", isOn: $keepAlive)
                                Text("Ping idle connections every 30 seconds.").font(.caption)
                            }.padding(5).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GroupBox("CSV defaults") {
                        HStack(alignment: .top, spacing: 22) {
                            Form {
                                Picker("Delimiter", selection: $separator) { Text("Comma").tag(","); Text("Semicolon").tag(";"); Text("Tab").tag("\t") }
                                Picker("Line ending", selection: $ending) { Text("LF").tag("LF"); Text("CRLF").tag("CRLF") }
                                TextField("NULL token", text: $nullToken)
                            }
                            VStack(alignment: .leading) {
                                Toggle("Include CSV header", isOn: $header)
                                Toggle("Quote all fields", isOn: $quoteAll)
                                Toggle("Decimal comma", isOn: $decimal)
                            }
                        }.padding(5)
                    }
                }.padding(10)
            }.tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Section("SQL editor") {
                    Toggle("Automatically save SQL recovery drafts while editing", isOn: $drafts)
                    Toggle("Automatically uppercase SQL keywords", isOn: $uppercase)
                    Toggle("Automatically insert closing brackets and quotes", isOn: $pairs)
                    Picker("Accept completion with", selection: $completion) {
                        ForEach(["Explicit shortcut", "Tab", "Return", "Return or Tab"], id: \.self) { Text($0) }
                    }
                    Picker("Tab indentation", selection: $indent) { Text("Tab character").tag(0); ForEach([2,4,6,8], id: \.self) { Text("\($0) spaces").tag($0) } }
                }
            }.padding().tabItem { Label("Editor", systemImage: "text.cursor") }
            Form {
                Picker("Appearance", selection: $theme) { ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) } }
                FontAndColorSettings(editorSize: $font, gridSize: $gridFont)
                Toggle("Highlight SQL syntax", isOn: $highlight)
            }.padding().tabItem { Label("Appearance", systemImage: "textformat") }
            Form {
                LabeledContent("Connection library") { Text(library.directory.path).textSelection(.enabled) }
                HStack {
                    Button("Reveal Folder") { NSWorkspace.shared.open(library.directory) }
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                        if panel.runModal() == .OK, let folder = panel.url { changeLocation(folder) }
                    }
                    Button("Use Default Folder") { changeLocation(ConnectionLibrary.defaultDirectory()) }
                }
                StorageFolderRow(title: "Queries and history", key: "queryDirectory", fallback: library.directory)
                StorageFolderRow(title: "Workspace state", key: "stateDirectory", fallback: library.directory)
                Text("Folder changes apply to newly opened connections. Existing files stay in their original folder.").font(.caption)
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
            KeymapPreferences().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }.onChange(of: statementTimeout) { statementTimeout = min(86400, max(0, statementTimeout)) }
        .onChange(of: estimateThreshold) { estimateThreshold = max(1, estimateThreshold) }
        .padding(12).frame(width: 710, height: 510).background(BrowserChrome.paper).modifier(BrowserAppearance())
    }
    private func changeLocation(_ folder: URL) {
        do { try library.useDirectory(folder); locationError = nil }
        catch { locationError = error.localizedDescription }
    }
}
