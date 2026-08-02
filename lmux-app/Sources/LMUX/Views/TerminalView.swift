import SwiftUI
import SwiftTerm

struct TerminalView: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let existing = nsView.subviews.first, existing === manager.terminalView {
            existing.frame = nsView.bounds
            return
        }
        nsView.subviews.forEach { $0.removeFromSuperview() }
        guard let terminal = manager.terminalView, manager.isConnected else { return }
        terminal.frame = nsView.bounds
        terminal.autoresizingMask = [.width, .height]
        nsView.addSubview(terminal)

        // Event monitor: intercept Return, send both \r (terminal standard) and \n (raw-mode apps need this)
        if let window = nsView.window, window !== context.coordinator.targetWindow {
            context.coordinator.watchWindow(window, terminal: terminal)
        }
        nsView.window?.makeFirstResponder(terminal)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var eventMonitor: Any?
        weak var targetWindow: NSWindow?

        func watchWindow(_ window: NSWindow, terminal: LocalProcessTerminalView) {
            removeMonitor()
            targetWindow = window
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak terminal] event in
                guard event.keyCode == 36, event.window === window, let t = terminal else { return event }
                Task { @MainActor in t.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
                return nil
            }
        }

        func removeMonitor() {
            if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
            targetWindow = nil
        }
    }
}
