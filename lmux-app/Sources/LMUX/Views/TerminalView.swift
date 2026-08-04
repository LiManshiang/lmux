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
        container.postsBoundsChangedNotifications = true

        // Track live-resize start/end via bounds change notifications
        context.coordinator.resizeObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: container,
            queue: .main
        ) { [weak container, weak coordinator, weak manager] _ in
            guard let container,
                  let coordinator,
                  let terminal = manager?.terminalView,
                  manager?.isConnected == true,
                  terminal.superview === container
            else { return }

            let newSize = container.bounds.size
            guard terminal.frame.size != newSize else { return }

            if container.inLiveResize {
                coordinator.applyStretchTransform(terminal: terminal, toFill: newSize)
            } else {
                coordinator.applyFinalSize(terminal: terminal, size: newSize)
            }
        }

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let terminal = manager.terminalView, manager.isConnected else {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.savedSize = nil
            return
        }

        if terminal.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.savedSize = nil
            terminal.frame = nsView.bounds
            terminal.autoresizingMask = []
            nsView.addSubview(terminal)
            nsView.window?.makeFirstResponder(terminal)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let observer = coordinator.resizeObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.resizeObserver = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var savedSize: NSSize?
        var resizeObserver: NSObjectProtocol?

        /// During live resize, visually stretch the content via transform instead
        /// of triggering TIOCSWINSZ + buffer reflow + Metal redraw.
        func applyStretchTransform(terminal: NSView, toFill containerSize: NSSize) {
            // Save the "real" size so we know where to snap back
            if savedSize == nil { savedSize = terminal.frame.size }

            guard let realSize = savedSize, realSize.width > 0, realSize.height > 0 else { return }

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            // Position centered, then scale to fill container
            let sx = containerSize.width / realSize.width
            let sy = containerSize.height / realSize.height
            let scale = min(sx, sy)
            let scaledW = realSize.width * scale
            let scaledH = realSize.height * scale
            let dx = (containerSize.width - scaledW) / 2
            let dy = (containerSize.height - scaledH) / 2

            terminal.frame.origin = NSPoint(x: dx, y: dy)
            terminal.frame.size = realSize
            terminal.layer?.affineTransform = CGAffineTransform(scaleX: scale, y: scale)

            CATransaction.commit()
        }

        /// Resize ends: remove transform, apply exact frame (triggers TIOCSWINSZ once).
        func applyFinalSize(terminal: NSView, size: NSSize) {
            savedSize = nil

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            terminal.layer?.affineTransform = .identity
            terminal.frame.origin = .zero
            terminal.frame.size = size

            CATransaction.commit()
        }
    }
}
