import AppKit
import SwiftUI

/// Owns a single, reusable settings window (PreferencesView inside a titled
/// NSWindow with traffic-light close button). Opened from the app menu
/// "Settings…" (Cmd+,) and the sidebar (⋯) menu — closing it keeps the window
/// around so reopening is instant.
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func open(viewModel: ContentViewModel) {
        if let window {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(rootView: PreferencesView().environmentObject(viewModel))
        let newWindow = NSWindow(contentViewController: host)
        newWindow.title = "lmux Settings"
        newWindow.setContentSize(NSSize(width: 600, height: 470))
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Keep it after close so the same window is reused next time.
        newWindow.isReleasedWhenClosed = false
        newWindow.tabbingMode = .disallowed
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
    }
}
