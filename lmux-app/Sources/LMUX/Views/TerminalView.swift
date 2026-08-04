import SwiftUI
import SwiftTerm

struct PTYTerminalView: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager

    func makeNSView(context: Context) -> NSView {
        // Enable SwiftTerm's Metal live-resize throttling for smoother window resize
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
            context.coordinator.pendingResize = nil
            return
        }

        if terminal.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            terminal.frame = nsView.bounds
            terminal.autoresizingMask = [.width, .height]
            nsView.addSubview(terminal)
            nsView.window?.makeFirstResponder(terminal)
            return
        }

        let newSize = nsView.bounds.size
        guard terminal.frame.size != newSize else { return }

        // During live resize, debounce: only apply every ~100ms to skip intermediate frames.
        // When the resize ends, the final frame is applied immediately.
        if nsView.inLiveResize {
            context.coordinator.scheduleResize(terminal: terminal, size: newSize)
        } else {
            context.coordinator.cancelPendingResize()
            applySize(terminal: terminal, size: newSize)
        }
    }

    private func applySize(terminal: NSView, size: NSSize) {
        guard terminal.frame.size != size else { return }
        terminal.frame.size = size
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var pendingResize: DispatchWorkItem?

        func scheduleResize(terminal: NSView, size: NSSize) {
            pendingResize?.cancel()
            let work = DispatchWorkItem { [weak terminal] in
                guard let terminal else { return }
                if terminal.frame.size != size {
                    terminal.frame.size = size
                }
            }
            pendingResize = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }

        func cancelPendingResize() {
            pendingResize?.cancel()
            pendingResize = nil
        }
    }
}
