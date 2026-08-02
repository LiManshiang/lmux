import SwiftUI
import SwiftTerm

/// SwiftUI wrapper for SwiftTerm's LocalProcessTerminalView.
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
            // already showing the correct terminal
            existing.frame = nsView.bounds
            return
        }
        nsView.subviews.forEach { $0.removeFromSuperview() }

        guard let terminal = manager.terminalView, manager.isConnected else { return }
        terminal.frame = nsView.bounds
        terminal.autoresizingMask = [.width, .height]
        nsView.addSubview(terminal)
    }
}
