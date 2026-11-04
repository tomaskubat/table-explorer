import AppKit
import SwiftUI

/// Intercept the standard close button and Cmd-W while a draft or operation is
/// live. Keep SwiftUI's own window delegate responsible for everything else.
struct WorkspaceWindowGuard: NSViewRepresentable {
    let workspace: Workspace

    func makeCoordinator() -> Coordinator { Coordinator(workspace) }
    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: HookView, context: Context) { context.coordinator.attach(to: view.window) }
    static func dismantleNSView(_ view: HookView, coordinator: Coordinator) { coordinator.detach() }

    final class HookView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(to: window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let workspace: Workspace
        private weak var window: NSWindow?
        // AppKit dispatches window delegate callbacks on the main thread. The
        // Objective-C forwarding hooks themselves have no isolation annotations.
        nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
        init(_ workspace: Workspace) { self.workspace = workspace }
        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            detach()
            original = window.delegate; self.window = window; window.delegate = self
        }
        func detach() {
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
            guard workspace.hasDrafts || workspace.hasRunningTasks else {
                return original?.windowShouldClose?(sender) ?? true
            }
            guard sender.attachedSheet == nil else { return false }
            let alert = NSAlert()
            if workspace.hasRunningTasks {
                alert.messageText = "A database operation is running"
                alert.informativeText = "Wait for the operation to finish before closing this workspace."
                alert.addButton(withTitle: "Keep Open")
                alert.beginSheetModal(for: sender)
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
                        sender?.performClose(nil)
                    }
                }
            }
            return false
        }
    }
}
