import AppKit
import SwiftUI

/// Brings the main window back when it has been closed with the red button.
///
/// Closing it used to be one-way. The only affordance that promised to show the
/// app again — the menu bar item's "Show lmux" — called `NSApp.activate` and
/// nothing else, which leaves the window exactly where it was, so the app looked
/// unrecoverable until relaunch. AppKit's own reopen handling does not fill the
/// gap either: measured on this Mac, four Dock clicks activated the app and left
/// the closed window closed, every time.
///
/// The window survives being closed — it is ordered out, not destroyed, which is
/// what this relies on and what it also enforces. Two things make that certain:
/// holding it here, so nothing SwiftUI does can drop the last reference, and
/// `isReleasedWhenClosed = false`, so AppKit does not release it either. This is
/// the same shape `SettingsWindowController` and `SessionWindowController`
/// already use for their windows.
///
/// Deliberately not SwiftUI's `openWindow` action, which would be the other way
/// to get a window back: it is macOS 13+ and this ships for 12, and it does not
/// reuse a closed window — it adds another one. Measured before that was
/// understood: three shows, three windows.
@MainActor
enum MainWindow {
    /// The main window. Strong on purpose — see above.
    private static var window: NSWindow?

    /// Called by the capture view once the main view is in its window.
    static func remember(_ window: NSWindow?) {
        guard let window else { return }
        // Closed windows are reused here rather than recreated, so the close
        // must not destroy it.
        window.isReleasedWhenClosed = false
        self.window = window
    }

    /// Show the main window and bring the app forward, whether it is closed,
    /// minimized, or already on screen.
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Reports the window the main view is in, so `MainWindow` can bring it back
/// after a close.
///
/// `view.window` is still nil while SwiftUI builds this and is set once the view
/// is in a window, so the read is deferred a turn of the run loop. A nil read is
/// ignored there: this also runs on passes where the view is not attached yet,
/// and overwriting a good reference with nil would cost the only handle to the
/// window.
struct MainWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let view = nsView
        DispatchQueue.main.async { MainWindow.remember(view.window) }
    }
}
