import SwiftUI

enum BrowserAction: String, CaseIterable {
    case newQuery = "New Query", connections = "Saved Connections", document = "New SQL Document", openFile = "Open SQL File"
    case close = "Close Tab", save = "Save / Commit", search = "Open Anything", console = "SQL Console"
    case nextTab = "Select Next Tab", previousTab = "Select Previous Tab", nextWorkspace = "Select Next Workspace", previousWorkspace = "Select Previous Workspace"
    case nextPane = "Select Next Pane", previousPane = "Select Previous Pane", data = "Show Table Data", structure = "Show Table Structure"
    case add = "Add Row", duplicate = "Duplicate Rows", detail = "Row Detail", filters = "Show Filters", columns = "Choose Columns"
    case back = "Previous Page", forward = "Next Page", preview = "Preview Changes"
    case run = "Run Current / Apply Filters", comment = "Toggle Line Comment", block = "Toggle Block Comment", complete = "Complete SQL"
    case bigger = "Increase Editor Font Size", smaller = "Decrease Editor Font Size"

    var standard: KeyBinding {
        switch self {
        case .newQuery: .init("t"); case .connections: .init("n"); case .document: .init("n", [.command,.shift])
        case .openFile: .init("o"); case .close: .init("w"); case .save: .init("s"); case .search: .init("p")
        case .console: .init("c", [.command,.shift]); case .nextTab: .init("]"); case .previousTab: .init("[")
        case .nextWorkspace: .init("]", [.command,.shift]); case .previousWorkspace: .init("[", [.command,.shift])
        case .nextPane: .init("]", [.command,.option]); case .previousPane: .init("[", [.command,.option])
        case .data: .init("[", [.command,.control]); case .structure: .init("]", [.command,.control])
        case .add: .init("i"); case .duplicate: .init("d"); case .detail: .init(" ", []); case .filters: .init("f")
        case .columns: .init("f", [.command,.option]); case .back: .init(String(KeyEquivalent.leftArrow.character))
        case .forward: .init(String(KeyEquivalent.rightArrow.character)); case .preview: .init("p", [.command,.shift])
        case .run: .init("\r"); case .comment: .init("/"); case .block: .init("/", [.command,.option])
        case .complete: .init("\u{1b}", .option); case .bigger: .init("="); case .smaller: .init("-")
        }
    }
}

struct KeyBinding: Codable, Equatable {
    let key: String
    let mask: Int
    var flags: EventModifiers { EventModifiers(rawValue: mask) }
    init(_ key: String, _ flags: EventModifiers = .command) { self.key = key; mask = flags.rawValue }
    static let none = Self("", [])
    var shortcut: KeyboardShortcut? {
        key.first.map { KeyboardShortcut(KeyEquivalent($0), modifiers: flags, localization: .custom) }
    }
    var display: String {
        guard !key.isEmpty else { return "Unassigned" }
        let names = ["\r":"Return", "\t":"Tab", " ":"Space", "\u{1b}":"Esc",
                     String(KeyEquivalent.leftArrow.character):"←", String(KeyEquivalent.rightArrow.character):"→",
                     String(KeyEquivalent.upArrow.character):"↑", String(KeyEquivalent.downArrow.character):"↓"]
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") +
            (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + (names[key] ?? key.uppercased())
    }
    init?(event: NSEvent) {
        guard let key = event.characters(byApplyingModifiers: [])?.lowercased(), key.count == 1 else { return nil }
        var flags = EventModifiers()
        for (native, flag): (NSEvent.ModifierFlags, EventModifiers) in [(.command,.command),(.control,.control),(.option,.option),(.shift,.shift)] {
            if event.modifierFlags.contains(native) { flags.insert(flag) }
        }
        self.init(key, flags)
    }
}

struct Keymap {
    static let key = "commandKeymap.v1"
    var overrides: [String: KeyBinding]
    init(_ data: Data) { overrides = data.isEmpty ? [:] : ((try? JSONDecoder().decode([String: KeyBinding].self, from: data)) ?? [:]) }
    static var saved: Self { Self(BrowserPreferences.defaults.data(forKey: key) ?? Data()) }
    subscript(_ action: BrowserAction) -> KeyBinding { overrides[action.rawValue] ?? action.standard }
    func issue(_ binding: KeyBinding, for action: BrowserAction) -> String? {
        guard binding != .none else { return nil }
        if binding.flags.intersection([.command,.control,.option]).isEmpty && !(action == .detail && binding == action.standard) {
            return "Include Command, Control, or Option."
        }
        if (binding.flags == .command && [",","q","x","c","v","z","a","m","h","\t"," "].contains(binding.key))
            || (binding.flags == [.command,.shift] && ["z","q"].contains(binding.key)) || binding.key == "\u{7f}" {
            return "This shortcut is reserved by macOS."
        }
        if let other = BrowserAction.allCases.first(where: { $0 != action && self[$0] == binding }) {
            return "Already assigned to " + other.rawValue + "."
        }
        return nil
    }
}

struct KeymapPreferences: View {
    @AppStorage(Keymap.key, store: BrowserPreferences.defaults) private var data = Data()
    @State private var recording: BrowserAction?
    @State private var message: String?
    @State private var search = ""
    private var map: Keymap { Keymap(data) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Filter shortcuts", text: $search)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(BrowserAction.allCases.filter { search.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(search) }, id: \.self) { action in
                        HStack {
                            Text(action.rawValue); Spacer()
                            Button(recording == action ? "Press shortcut…" : map[action].display) { message = nil; recording = action }
                                .frame(width: 155).accessibilityIdentifier("Shortcut " + action.rawValue)
                            Button { assign(.none, action) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).accessibilityLabel("Clear " + action.rawValue)
                        }.padding(.horizontal, 8).frame(height: 31)
                        Divider()
                    }
                }
            }
            HStack {
                Text(message ?? (recording == nil ? "Click a shortcut to change it." : "Press Escape to cancel.")).font(.callout)
                Spacer(); Button("Restore Defaults") { recording = nil; data = Data(); message = nil }
            }
        }.padding(12).background {
            if let action = recording {
                KeyCapture { event in
                    if event.keyCode == 53 && event.modifierFlags.intersection([.command,.shift,.option,.control]).isEmpty { recording = nil }
                    else if let binding = KeyBinding(event: event) { assign(binding, action) }
                }.id(action)
            }
        }
    }
    private func assign(_ binding: KeyBinding, _ action: BrowserAction) {
        var changed = map
        if let issue = changed.issue(binding, for: action) { message = issue; return }
        changed.overrides[action.rawValue] = binding == action.standard ? nil : binding
        if let encoded = try? JSONEncoder().encode(changed.overrides) { data = encoded }
        recording = nil; message = nil
    }
}

private struct KeyCapture: NSViewRepresentable {
    let receive: (NSEvent) -> Void
    final class Host: NSView {
        var monitor: Any?
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
    }
    func makeNSView(context: Context) -> Host {
        let view = Host()
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            guard let window = view?.window, window.isKeyWindow, event.window === window else { return event }
            receive(event); return nil
        }
        return view
    }
    func updateNSView(_ view: Host, context: Context) {}
    static func dismantleNSView(_ view: Host, coordinator: ()) { view.stop() }
}
