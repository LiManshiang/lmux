import SwiftUI
import SwiftTerm
import QuartzCore

struct PTYTerminalView: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager

    func makeNSView(context: Context) -> NSView {
        if ProcessInfo.processInfo.environment["SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE"] == nil {
            setenv("SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE", "", 0)
        }

        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let terminal = manager.terminalView, manager.isConnected else {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.clear()
            return
        }

        if terminal.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.clear()
            terminal.frame = nsView.bounds
            terminal.autoresizingMask = []
            nsView.addSubview(terminal)
            nsView.window?.makeFirstResponder(terminal)
            return
        }

        let containerSize = nsView.bounds.size
        guard containerSize != terminal.frame.size else { return }

        if nsView.window?.inLiveResize == true {
            context.coordinator.stretch(terminal: terminal, to: containerSize)
        } else {
            context.coordinator.snapToFinal(terminal: terminal, size: containerSize)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var savedSize: NSSize?

        func clear() {
            savedSize = nil
        }

        /// Live resize: keep real pixel size, visually stretch with CATransform.
        func stretch(terminal: NSView, to containerSize: NSSize) {
            if savedSize == nil { savedSize = terminal.frame.size }
            guard let real = savedSize, real.width > 0, real.height > 0 else { return }

            let sx = containerSize.width / real.width
            let sy = containerSize.height / real.height
            let scale = min(sx, sy)
            let dx = (containerSize.width - real.width * scale) / 2
            let dy = (containerSize.height - real.height * scale) / 2

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            terminal.frame.origin = NSPoint(x: dx, y: dy)
            terminal.frame.size = real
            terminal.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
            CATransaction.commit()
        }

        /// Resize ended: remove transform, apply exact frame (TIOCSWINSZ once).
        func snapToFinal(terminal: NSView, size: NSSize) {
            let wasStretched = savedSize != nil
            savedSize = nil

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            if wasStretched {
                terminal.layer?.setAffineTransform(.identity)
                terminal.frame.origin = .zero
            }

            terminal.frame.size = size
            CATransaction.commit()
        }
    }
}
