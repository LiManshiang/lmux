import AppKit

/// Abstract rendering + PTY backend. Two implementations ship:
/// `SwiftTermBackend` (forkpty stack) and `GhosttyBackend` (libghostty,
/// macOS 13+). `TerminalManager` depends only on this protocol.
@MainActor
protocol TerminalBackend: AnyObject {
    /// The renderer's NSView, embedded by PTYTerminalView.
    var view: NSView { get }

    /// PID of the foreground shell/agent process. 0 while not running.
    /// Semantics differ per backend (SwiftTerm: forkpty shell pid; Ghostty:
    /// `tcgetpgrp(pty)`) — see INTEGRATION_PLAN.md §6.
    var processPID: Int32 { get }
    var isProcessRunning: Bool { get }

    /// PID used as the root of agent-detection's descendant walk. This must
    /// be the stable shell PID (the process the user types into), NOT the
    /// current foreground PID — Ghostty's foregroundPid changes to whichever
    /// program owns the pty, so walking its descendants would miss the agent
    /// the user launched inside the shell. SwiftTerm's processPID is already
    /// the forkpty shell pid, so it returns the same value.
    var detectionRootPID: Int32 { get }

    // MARK: - Callbacks (injected by TerminalManager)

    /// Fired when the process produces its first terminal output.
    var onFirstOutput: (() -> Void)? { get set }
    /// Fired on any terminal output (drives idle detection).
    var onActivity: (() -> Void)? { get set }
    /// Fired when the foreground process exits.
    var onProcessExit: (() -> Void)? { get set }
    /// Fired on terminal title changes.
    var onTitleChange: ((String) -> Void)? { get set }
    /// Fired on OSC 777/9 desktop notifications. (title, body)
    var onNotify: ((String, String) -> Void)? { get set }
    /// Fired when a spawn/launch fails after `start*` returned true.
    var onConnectError: ((String) -> Void)? { get set }

    // MARK: - Lifecycle

    /// Spawn an agent (executable + args) in `cwd` with the given environment.
    /// Returns true when the launch was accepted; genuine failures surface
    /// later through `onConnectError` / `onProcessExit`.
    @discardableResult
    func startAgent(executable: String, args: [String], env: [String], cwd: String) -> Bool

    /// Spawn a shell in `cwd`.
    @discardableResult
    func startBash(cwd: String, env: [String]) -> Bool

    /// Kill the process.
    func terminate()
    /// Detach without killing: keep the process and surface alive.
    func detach()
    /// Re-attach to the still-alive process.
    func reattach()

    // MARK: - I/O

    /// Send text into the terminal as if the user typed it.
    func sendInput(_ text: String)

    // MARK: - Configuration

    func applyTheme(_ theme: TerminalTheme)
    func setScrollback(_ lines: Int)
}

/// Backend selection key in UserDefaults.
enum TerminalRendererSetting {
    static let key = "terminalRenderer"
    static let swiftterm = "swiftterm"
    static let ghostty = "ghostty"
}

/// Creates backends per the user's renderer selection. Defaults to Ghostty
/// on this branch (GPU rendering, macOS 13+); SwiftTerm remains selectable.
@MainActor
enum TerminalBackendFactory {
    /// The value that is used when the user never made an explicit choice.
    static var defaultRenderer: String { TerminalRendererSetting.ghostty }

    /// Resolve the selected renderer, falling back to the branch default.
    static var selectedRenderer: String {
        UserDefaults.standard.string(forKey: TerminalRendererSetting.key) ?? defaultRenderer
    }

    static func make() -> TerminalBackend {
        switch selectedRenderer {
        case TerminalRendererSetting.ghostty:
            return GhosttyBackend()
        default:
            return SwiftTermBackend()
        }
    }

    /// The human-readable label of the active backend (for preferences UI).
    static var currentName: String {
        selectedRenderer == TerminalRendererSetting.ghostty ? "Ghostty (libghostty)" : "SwiftTerm"
    }

    static var isGhosttySelected: Bool {
        selectedRenderer == TerminalRendererSetting.ghostty
    }
}
