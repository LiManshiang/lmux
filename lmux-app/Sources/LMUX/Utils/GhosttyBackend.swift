import AppKit
import GhosttyTerminal
import LMUXCore

/// libghostty-backed implementation of `TerminalBackend` (macOS 13+).
///
/// Uses GhosttyKit's `.exec` backend: libghostty owns the PTY and spawns the
/// shell/agent, so the host only supplies workingDirectory/envVars/command.
///
/// Idle/first-output detection: the exec backend does not hand the host raw
/// bytes, so we poll the visible viewport text (`readViewportText`) and fire
/// `onActivity`/`onFirstOutput` on changes — equivalent to SwiftTerm's
/// `dataReceived` for lmux's 2s/3s idle timers.
@MainActor
final class GhosttyBackend: TerminalBackend {
    private let controller: TerminalController
    private let viewState: TerminalViewState
    private(set) var terminalView: TerminalView?
    /// Stable placeholder so `view` never allocates per access.
    private var placeholder = TerminalView(frame: .zero)

    var view: NSView { terminalView ?? placeholder }

    var processPID: Int32 {
        guard let pid = terminalView?.foregroundPid, pid > 0 else { return 0 }
        return pid
    }

    var isProcessRunning: Bool {
        viewState.surface != nil && terminalView?.foregroundPid != nil
    }

    // MARK: - Callbacks

    var onFirstOutput: (() -> Void)?
    var onActivity: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onNotify: ((String, String) -> Void)?
    var onConnectError: ((String) -> Void)?

    // MARK: - State

    /// True once the foreground PID has been observed, distinguishing a real
    /// process exit from a spawn failure (surface closed before ever running).
    private var didSeePid = false
    /// Last viewport text hash, used to detect output for idle/first-output.
    private var lastViewportHash: Int?
    /// Last desktop-notification title/body seen, to bridge OSC 777/9.
    private var lastNotifyTitle: String?
    private var lastNotifyBody: String?
    /// Last title seen.
    private var lastTitle: String?
    /// Poll timer for idle / notification / title bridging.
    private var pollTimer: Timer?
    /// PID observed at spawn time (the shell), used as agent-detection root.
    private(set) var shellPID: Int32 = 0

    init() {
        // App-level config singleton: ghostty runtime init is one-shot and
        // config parsing is expensive; share it across sessions.
        let shared = TerminalController.shared
        controller = shared
        viewState = TerminalViewState(controller: shared)

        // Process exit: Ghostty reports via close_surface_cb (processAlive).
        viewState.onClose = { [weak self] processAlive in
            Task { @MainActor in
                self?.handleSurfaceClosed(processAlive: processAlive)
            }
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    func startAgent(executable: String, args: [String], env: [String], cwd: String) -> Bool {
        start(command: shellCommand(executable: executable, args: args), env: env, cwd: cwd)
    }

    @discardableResult
    func startBash(cwd: String, env: [String]) -> Bool {
        start(command: "/bin/zsh -l", env: env, cwd: cwd)
    }

    @discardableResult
    private func start(command: String, env: [String], cwd: String) -> Bool {
        // Reuse an existing view's surface if one is still alive (restore
        // racing with a manual connect must not double-spawn).
        if terminalView != nil, viewState.surface != nil {
            return true
        }

        let view = makeView()
        view.configuration = TerminalSurfaceOptions(
            backend: .exec,
            fontSize: 12,
            workingDirectory: cwd,
            envVars: envDict(env),
            command: command,
            context: .window
        )
        terminalView = view

        didSeePid = false
        shellPID = 0
        startPolling()
        return true
    }

    func terminate() {
        stopPolling()
        if let surface = viewState.surface {
            surface.close()
        }
        terminalView = nil
    }

    func detach() {
        // Keep the view + surface alive so the process keeps running. The
        // polling timer is intentionally NOT stopped: idle/exit must keep
        // updating the sidebar after switching sessions.
        // (SwiftTerm keeps its LocalProcessTerminalView alive the same way.)
    }

    func reattach() {
        // Surface and process are still alive; just re-mark connected.
        // Metrics re-sync happens in AppTerminalView.viewDidMoveToWindow.
    }

    // MARK: - I/O

    func sendInput(_ text: String) {
        viewState.surface?.sendText(text)
    }

    // MARK: - Configuration

    func applyTheme(_ lmuxTheme: TerminalTheme) {
        // Ghostty resolves the final config as base + terminalConfiguration +
        // theme, with theme applied LAST so it wins for duplicate keys. The
        // default theme (Afterglow/Alabaster) would otherwise override our
        // colors, so the lmux theme must be pushed as the *theme*, not as a
        // terminalConfiguration override.
        let cfg = lmuxTheme.ghosttyConfiguration()
        let ghosttyTheme = GhosttyTerminal.TerminalTheme(light: cfg, dark: cfg)
        controller.setTheme(ghosttyTheme)
    }

    func setScrollback(_ lines: Int) {
        // scrollback-limit is a config key in Ghostty.
        let config = TerminalConfiguration(startingFrom: .init()) {
            $0.withCustom("scrollback-limit", "\(lines)")
        }
        controller.setTerminalConfiguration(config)
    }

    // MARK: - View construction

    private func makeView() -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.controller = controller
        view.delegate = viewState
        return view
    }

    // MARK: - Polling (idle / notifications / title / PID)

    private func startPolling() {
        pollTimer?.invalidate()
        lastViewportHash = nil
        lastNotifyTitle = nil
        lastNotifyBody = nil
        lastTitle = nil
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard let surface = viewState.surface else {
            // Surface not created yet (view not yet attached) — wait.
            return
        }

        // PID: capture the spawn-time shell PID once for agent detection.
        if shellPID == 0, let pid = terminalView?.foregroundPid, pid > 0 {
            shellPID = pid
            didSeePid = true
        }

        // Title bridging.
        if viewState.title != lastTitle {
            lastTitle = viewState.title
            if !viewState.title.isEmpty {
                onTitleChange?(viewState.title)
            }
        }

        // OSC 777/9 desktop notification bridging.
        if let t = viewState.lastDesktopNotificationTitle,
           let b = viewState.lastDesktopNotificationBody,
           t != lastNotifyTitle || b != lastNotifyBody {
            lastNotifyTitle = t
            lastNotifyBody = b
            onNotify?(t, b)
        }

        // Idle / first-output via viewport text hash.
        guard let text = surface.readViewportText() else { return }
        let hash = text.hashValue
        if lastViewportHash == nil {
            // First poll: seed only if there is already content (e.g. an
            // agent printed during startup before we started polling).
            if !text.isEmpty {
                lastViewportHash = hash
                onFirstOutput?()
                onActivity?()
            }
        } else if hash != lastViewportHash {
            lastViewportHash = hash
            onActivity?()
        }
    }

    private func handleSurfaceClosed(processAlive: Bool) {
        if processAlive {
            // Surface closed but process still alive (host-requested close
            // or detach) — nothing to do.
            return
        }
        stopPolling()
        if didSeePid {
            onProcessExit?()
        } else {
            // Surface closed before the process ever produced a PID: spawn
            // failed (e.g. command not found).
            onConnectError?("Failed to launch process via libghostty.")
        }
    }

    // MARK: - Helpers

    /// Convert `["KEY=VALUE", ...]` to a dictionary.
    private func envDict(_ env: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in env {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<eq])
            let value = String(entry[entry.index(after: eq)...])
            out[key] = value
        }
        return out
    }

    /// Ghostty's `.exec` backend takes a shell command string. Quote each arg
    /// so paths with spaces survive (same policy as the file-drop quoting).
    private func shellCommand(executable: String, args: [String]) -> String {
        let parts = ([executable] + args).map(Self.shellQuote)
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        if s.contains(" ") || s.contains("\t") || s.contains("'") {
            let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return s
    }
}

// MARK: - Theme bridge (lmux TerminalTheme -> Ghostty TerminalConfiguration)

extension TerminalTheme {
    /// Bridge this lmux theme into a Ghostty TerminalConfiguration.
    ///
    /// The font size is pinned to 12 to match the surface's `fontSize: 12` —
    /// otherwise applying the theme re-resolves the config and the base
    /// template's default 14pt overrides the surface size, making text jump.
    func ghosttyConfiguration() -> TerminalConfiguration {
        TerminalConfiguration {
            $0.withFontSize(12)
            $0.withBackground(TerminalColorBridge.hex(background))
            $0.withForeground(TerminalColorBridge.hex(foreground))
            $0.withSelectionBackground(TerminalColorBridge.hex(selection))
            $0.withCursorColor(TerminalColorBridge.hex(cursor))
            for (index, color) in ansi.enumerated() {
                $0.withPalette(index, color: TerminalColorBridge.hex(color))
            }
        }
    }
}
