import SwiftUI
import SwiftTerm

struct PTYTerminalView: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let terminal = manager.terminalView, manager.isConnected else {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        if terminal.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = nsView.bounds
            terminal.autoresizingMask = [.width, .height]
            nsView.addSubview(terminal)
            nsView.window?.makeFirstResponder(terminal)
        } else {
            terminal.frame = nsView.bounds
        }
    }
}
