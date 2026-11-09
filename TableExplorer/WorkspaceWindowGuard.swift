import AppKit
import SwiftUI

/// Protect window closure independently of the workspace tab shortcuts.
struct WorkspaceWindowGuard: NSViewRepresentable {
    let workspace: Workspace
    let closeActiveTab: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(workspace, closeActiveTab: closeActiveTab) }
    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: HookView, context: Context) {
        context.coordinator.closeActiveTab = closeActiveTab
        context.coordinator.attach(to: view.window)
    }
    static func dismantleNSView(_ view: HookView, coordinator: Coordinator) { coordinator.detach() }

    final class HookView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(to: window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let workspace: Workspace
        private weak var window: NSWindow?
        var closeActiveTab: () -> Void
        private var shortcutMonitor: Any?
        private var placement: WorkspaceWindowPlacement?
        // AppKit dispatches window delegate callbacks on the main thread. The
        // Objective-C forwarding hooks themselves have no isolation annotations.
        nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
        init(_ workspace: Workspace, closeActiveTab: @escaping () -> Void) {
            self.workspace = workspace; self.closeActiveTab = closeActiveTab
        }
        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            detach()
            original = window.delegate; self.window = window; workspace.window = window; window.delegate = self
            placement = WorkspaceWindowPlacement(window)
            // Native documents and sheets keep their own Save and Close commands.
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, let window, window.isKeyWindow, window.attachedSheet == nil,
                      event.window === window, !event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      let binding = KeyBinding(event: event) else { return event }
                let map = Keymap.saved
                if binding == map[.save] { self.workspace.saveActiveTab() }
                else if binding == map[.close], self.workspace.active != nil { self.closeActiveTab() }
                else { return event }
                return nil
            }
        }
        func detach() {
            placement = nil
            if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
            if workspace.window === window { workspace.window = nil }
            if window?.delegate === self { window?.delegate = original }
            window = nil; original = nil
        }
        override nonisolated func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { original?.responds(to: selector) == true }
        }
        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            dispatchPrecondition(condition: .onQueue(.main))
            return original
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard workspace.hasDrafts || !workspace.unsavedQueries.isEmpty || workspace.hasRunningTasks else {
                return original?.windowShouldClose?(sender) ?? true
            }
            guard sender.attachedSheet == nil else { return false }
            let alert = NSAlert()
            if workspace.hasRunningTasks {
                alert.messageText = "A database operation is running"
                alert.informativeText = "Wait for the operation to finish before closing this workspace."
                alert.addButton(withTitle: "Keep Open")
                alert.beginSheetModal(for: sender)
            } else if !workspace.hasDrafts {
                alert.messageText = "Save SQL changes before closing?"
                alert.informativeText = workspace.unsavedQueries.map(\.title).joined(separator: ", ")
                alert.addButton(withTitle: "Keep Editing")
                alert.addButton(withTitle: "Save and Close")
                alert.addButton(withTitle: "Discard and Close")
                alert.beginSheetModal(for: sender) { [weak self, weak sender] choice in
                    guard let self, choice != .alertFirstButtonReturn else { return }
                    do {
                        for tab in self.workspace.unsavedQueries {
                            if choice == .alertSecondButtonReturn {
                                guard try self.workspace.saveSQL(tab) else { return }
                            } else { tab.sql = tab.savedSQL }
                        }
                        self.closeAfterSheet(sender)
                    } catch { self.workspace.error = error.localizedDescription }
                }
            } else {
                alert.messageText = "Close with pending changes?"
                alert.informativeText = "Review the SQL before committing, or discard the drafts in this workspace."
                alert.addButton(withTitle: "Keep Editing")
                alert.addButton(withTitle: "Review Changes")
                alert.addButton(withTitle: "Discard and Close")
                alert.beginSheetModal(for: sender) { [weak self, weak sender] choice in
                    guard let self else { return }
                    if choice == .alertSecondButtonReturn, let tab = self.workspace.tabs.first(where: { !$0.changes.isEmpty }) {
                        self.workspace.activeID = tab.id; tab.showStructure = false; tab.previewShown = true
                    } else if choice == .alertThirdButtonReturn {
                        for tab in self.workspace.tabs { tab.discard() }
                        self.closeAfterSheet(sender)
                    }
                }
            }
            return false
        }

        private func closeAfterSheet(_ sender: NSWindow?) {
            // AppKit can ignore performClose while the sheet's completion handler is running.
            DispatchQueue.main.async { [weak sender] in sender?.performClose(nil) }
        }

        func windowWillClose(_ notification: Notification) {
            workspace.rememberOnClose()
            original?.windowWillClose?(notification)
        }
    }
}

/// Share one AppKit frame descriptor across workspace windows, without sharing
/// an autosave name (AppKit only allows one live window to own each name).
@MainActor private final class WorkspaceWindowPlacement: NSObject {
    private static let key = "workspaceWindowFrame"
    private weak var window: NSWindow?
    private var restored = false
    private var enteringFullScreen = false

    init(_ window: NSWindow) {
        self.window = window
        super.init()
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(restore(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            notifications.addObserver(self, selector: #selector(remember(_:)), name: name, object: window)
        }
        notifications.addObserver(self, selector: #selector(enterFullScreen(_:)), name: NSWindow.willEnterFullScreenNotification, object: window)
        notifications.addObserver(self, selector: #selector(exitFullScreen(_:)), name: NSWindow.didExitFullScreenNotification, object: window)
        if window.isKeyWindow { restore(nil) }
    }

    @objc private func restore(_ notification: Notification?) {
        guard !restored, let window else { return }
        if let frame = BrowserPreferences.defaults.string(forKey: Self.key), !window.styleMask.contains(.fullScreen) {
            window.setFrame(from: frame)
        }
        restored = true
    }

    @objc private func remember(_ notification: Notification) {
        guard restored, let window, window.isKeyWindow, !window.inLiveResize, !window.isMiniaturized,
              !enteringFullScreen, !window.styleMask.contains(.fullScreen), window.screen != nil else { return }
        BrowserPreferences.defaults.set(window.frameDescriptor, forKey: Self.key)
    }

    @objc private func enterFullScreen(_ notification: Notification) { enteringFullScreen = true }
    @objc private func exitFullScreen(_ notification: Notification) { enteringFullScreen = false }
}
