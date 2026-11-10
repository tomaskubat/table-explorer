import AppKit
import SwiftUI

/// Guard both individual connections and the shared window before releasing sessions.
struct WorkspaceWindowGuard: NSViewRepresentable {
    let registry: WorkspaceRegistry

    func makeCoordinator() -> Coordinator { Coordinator(registry) }
    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: HookView, context: Context) {
        context.coordinator.attach(to: view.window)
    }
    static func dismantleNSView(_ view: HookView, coordinator: Coordinator) { coordinator.detach() }

    final class HookView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(to: window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let registry: WorkspaceRegistry
        private weak var window: NSWindow?
        private var shortcutMonitor: Any?
        private var placement: WorkspaceWindowPlacement?
        // AppKit dispatches window delegate callbacks on the main thread. The
        // Objective-C forwarding hooks themselves have no isolation annotations.
        nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
        init(_ registry: WorkspaceRegistry) { self.registry = registry }
        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            detach()
            original = window.delegate; self.window = window; registry.window = window; window.delegate = self
            for workspace in registry.sessions.values { workspace.window = window }
            registry.closeHandler = { [weak self] workspace in self?.closeConnection(workspace) }
            placement = WorkspaceWindowPlacement(window)
            // Native documents and sheets keep their own Save and Close commands.
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, let window, window.isKeyWindow, window.attachedSheet == nil,
                      event.window === window, !event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      let binding = KeyBinding(event: event) else { return event }
                let map = Keymap.saved
                guard let workspace = self.registry.active else { return event }
                if binding == map[.save] { workspace.saveActiveTab() }
                else if binding == map[.close], workspace.active != nil { workspace.closeTabRequest = UUID() }
                else { return event }
                return nil
            }
        }
        func detach() {
            placement = nil
            if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
            if registry.window === window {
                for workspace in registry.sessions.values { workspace.window = nil }
                registry.window = nil; registry.closeHandler = nil
            }
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
            guard mayClose(registry.orderedSessions, retry: { [weak sender] in sender?.performClose(nil) }) else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        private func closeConnection(_ workspace: Workspace) {
            guard registry.sessions[workspace.id] === workspace,
                  mayClose([workspace], retry: { [weak self, weak workspace] in
                      if let workspace { self?.closeConnection(workspace) }
                  }) else { return }
            registry.remove(workspace)
            if registry.sessions.isEmpty { window?.performClose(nil) }
        }

        private func mayClose(_ targets: [Workspace], retry: @escaping @MainActor @Sendable () -> Void) -> Bool {
            guard let workspace = targets.first(where: \.hasRunningTasks)
                ?? targets.first(where: { $0.hasDrafts || !$0.unsavedQueries.isEmpty }) else { return true }
            guard let sender = window else { return false }
            guard sender.attachedSheet == nil else { return false }
            registry.activate(workspace.id)
            let alert = NSAlert()
            if workspace.hasRunningTasks {
                alert.messageText = "A database operation is running"
                alert.informativeText = "Wait for the operation in \(workspace.profile.name) to finish before closing it."
                alert.addButton(withTitle: "Keep Open")
                alert.beginSheetModal(for: sender)
            } else if !workspace.hasDrafts {
                alert.messageText = "Save SQL changes before closing?"
                alert.informativeText = workspace.profile.name + ": " + workspace.unsavedQueries.map(\.title).joined(separator: ", ")
                alert.addButton(withTitle: "Keep Editing")
                alert.addButton(withTitle: "Save and Close")
                alert.addButton(withTitle: "Discard and Close")
                alert.beginSheetModal(for: sender) { choice in
                    guard choice != .alertFirstButtonReturn else { return }
                    do {
                        for tab in workspace.unsavedQueries {
                            if choice == .alertSecondButtonReturn {
                                guard try workspace.saveSQL(tab) else { return }
                            } else { tab.sql = tab.savedSQL }
                        }
                        // Retry after AppKit finishes dismissing the confirmation sheet.
                        DispatchQueue.main.async(execute: retry)
                    } catch { workspace.error = error.localizedDescription }
                }
            } else {
                alert.messageText = "Close with pending changes?"
                alert.informativeText = "Review the SQL before committing, or discard the drafts in \(workspace.profile.name)."
                alert.addButton(withTitle: "Keep Editing")
                alert.addButton(withTitle: "Review Changes")
                alert.addButton(withTitle: "Discard and Close")
                alert.beginSheetModal(for: sender) { choice in
                    if choice == .alertSecondButtonReturn, let tab = workspace.tabs.first(where: { !$0.changes.isEmpty }) {
                        workspace.activeID = tab.id; tab.showStructure = false; tab.previewShown = true
                    } else if choice == .alertThirdButtonReturn {
                        for tab in workspace.tabs { tab.discard() }
                        DispatchQueue.main.async(execute: retry)
                    }
                }
            }
            return false
        }

        func windowWillClose(_ notification: Notification) {
            for workspace in registry.orderedSessions { registry.remove(workspace) }
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
