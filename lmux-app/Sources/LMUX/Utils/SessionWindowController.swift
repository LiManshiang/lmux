import AppKit
import SwiftUI

/// Opens sessions in their own terminal windows for parallel work. Each
/// session keeps its own TerminalManager + backend process, so several windows
/// can run different sessions at once (same-session double attach is refused
/// because a backend terminal can only live in one view).
@MainActor
final class SessionWindowController: NSObject {
    static let shared = SessionWindowController()

    /// Open windows keyed by session id.
    private var windows: [String: NSWindow] = [:]
    private weak var viewModel: ContentViewModel?

    override init() {}

    func open(session: SessionSummary, viewModel: ContentViewModel) {
        self.viewModel = viewModel
        // Refuse to double-attach a session that is currently displayed in the
        // main window (its TerminalManager is connected to the main terminal
        // view). Other sessions are detach/reattach-safe.
        if let mgr = viewModel.terminalManagerIfExists(for: session.id), mgr.isConnected {
            viewModel.showToast("Session '\(session.name)' is already open in the main window")
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if let window = windows[session.id] {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: SessionDetailView(pinnedSession: session)
                .environmentObject(viewModel)
        )
        let newWindow = NSWindow(contentViewController: host)
        newWindow.title = session.name
        newWindow.setContentSize(NSSize(width: 960, height: 640))
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        windows[session.id] = newWindow
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func isOpen(sessionID: String) -> Bool {
        windows[sessionID] != nil
    }
}

extension SessionWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let key = windows.first(where: { $0.value === window })?.key {
            windows.removeValue(forKey: key)
            // Detach the session's backend from the gone view: the process keeps
            // running in the background and the main window can reattach later.
            viewModel?.terminalManagerIfExists(for: key)?.detach()
        }
    }
}
