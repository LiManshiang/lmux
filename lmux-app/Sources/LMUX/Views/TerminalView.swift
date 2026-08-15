import SwiftUI
import QuartzCore
import AppKit

/// Terminal container that accepts dropped files/strings and forwards them
/// into the terminal as typed input (e.g. dropping a file inserts its path).
private final class TerminalContainerView: NSView {
    var onDrop: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // File URLs first (multiple files → space-separated, shell-quoted).
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL], !urls.isEmpty {
            let paths = urls.compactMap { $0.path }.map(Self.shellQuoted)
            onDrop?(paths.joined(separator: " ") + " ")
            return true
        }

        // Fallback: plain text drop.
        if let str = pb.string(forType: .string), !str.isEmpty {
            onDrop?(str)
            return true
        }
        return false
    }

    /// Quote a path for the shell when it contains whitespace.
    private static func shellQuoted(_ path: String) -> String {
        if path.contains(" ") || path.contains("\t") {
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return path
    }
}

struct PTYTerminalView: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager

    func makeNSView(context: Context) -> NSView {
        if ProcessInfo.processInfo.environment["SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE"] == nil {
            setenv("SWIFTTERM_METAL_LIVE_RESIZE_THROTTLE", "", 0)
        }

        let container = TerminalContainerView(frame: .zero)
        container.wantsLayer = true
        // Clip so a transiently overshooting terminal frame (e.g. during
        // live-resize stretch) can never paint over the header row above.
        // (NSView.clipsToBounds is macOS 14+; the layer property works on all.)
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
        let mgr = manager
        container.onDrop = { [weak mgr] text in
            mgr?.sendInput(text)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let terminal = manager.backend?.view, manager.isConnected else {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.clear()
            return
        }

        if terminal.superview !== nsView {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            context.coordinator.clear()
            terminal.frame = nsView.bounds
            terminal.autoresizingMask = [.width, .height]
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
            // Clamp to >= 0 so the stretched terminal never moves above or
            // left of the container (which would paint over the header row).
            let dx = max(0, (containerSize.width - real.width * scale) / 2)
            let dy = max(0, (containerSize.height - real.height * scale) / 2)

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
