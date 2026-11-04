import SwiftUI

struct StorageFolderRow: View {
    let title: String
    let key: String
    let fallback: URL
    @AppStorage private var path: String
    init(title: String, key: String, fallback: URL) {
        self.title = title; self.key = key; self.fallback = fallback
        _path = AppStorage(wrappedValue: "", key, store: BrowserPreferences.defaults)
    }
    var body: some View {
        LabeledContent(title) {
            Text(path.isEmpty ? "Library folder" : path).lineLimit(1).truncationMode(.middle).help(path.isEmpty ? fallback.path : path)
            Button("Choose…") {
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                if panel.runModal() == .OK, let folder = panel.url { path = folder.path }
            }
            Button("Default") { BrowserPreferences.defaults.removeObject(forKey: key) }.disabled(path.isEmpty)
        }
    }
}

enum FontChoice {
    static let choices = ["System", "System Mono", "System Mono Digit", "Menlo", "Monaco", "Helvetica"]
    static func font(_ family: String, _ size: Double) -> NSFont {
        switch family {
        case "System Mono": return .monospacedSystemFont(ofSize: size, weight: .regular)
        case "System Mono Digit": return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
        default: return NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
        }
    }
}
enum Ink: String, CaseIterable {
    case keyword = "Keywords", comment = "Comments", string = "Single quotes", quoted = "Double quotes", identifier = "Backticks", number = "Numbers", cell = "Cell text", empty = "NULL and empty cells"
    var standard: NSColor {
        switch self {
        case .keyword: .systemBlue; case .comment: .systemGreen; case .string,.quoted: .systemPink
        case .identifier: .systemOrange; case .number: .systemIndigo; case .cell: .labelColor; case .empty: .tertiaryLabelColor
        }
    }
}
struct InkPalette: Equatable {
    var colors: [String:String]
    init(_ data: Data) { colors = data.isEmpty ? [:] : ((try? JSONDecoder().decode([String:String].self, from: data)) ?? [:]) }
    func color(_ ink: Ink) -> NSColor { colors[ink.rawValue].flatMap { Color(statusHex: $0) }.map(NSColor.init) ?? ink.standard }
}
struct FontAndColorSettings: View {
    @Binding var editorSize: Double
    @Binding var gridSize: Double
    @AppStorage("editorFont", store: BrowserPreferences.defaults) private var editor = "System Mono"
    @AppStorage("gridFont", store: BrowserPreferences.defaults) private var grid = "System"
    @AppStorage("customInks", store: BrowserPreferences.defaults) private var data = Data()
    @State private var table = false
    var body: some View {
        Picker("Customize", selection: $table) { Text("SQL Editor").tag(false); Text("Data Table").tag(true) }.pickerStyle(.segmented)
        Picker("Font", selection: table ? $grid : $editor) { ForEach(FontChoice.choices, id: \.self) { Text($0) } }
        if table { Stepper("Data grid font: \(Int(gridSize)) pt", value: $gridSize, in: 9...24) }
        else { Stepper("Editor font: \(Int(editorSize)) pt", value: $editorSize, in: 9...28) }
        ForEach(table ? [Ink.cell,.empty] : [.keyword,.comment,.number,.string,.quoted,.identifier], id: \.self) { ink in
            ColorPicker(ink.rawValue, selection: Binding(get: { Color(nsColor: InkPalette(data).color(ink)) }, set: { value in
                var palette = InkPalette(data); palette.colors[ink.rawValue] = value.statusHex
                if let encoded = try? JSONEncoder().encode(palette.colors) { data = encoded }
            }), supportsOpacity: false)
        }
        Button("Restore Font and Color Defaults") { editor = "System Mono"; grid = "System"; editorSize = 13; gridSize = 14; data = Data() }
    }
}
