import AppKit
import SwiftTerm

/// SwiftTerm-backed implementation of `TerminalBackend`. This is the existing
/// lmux rendering stack (LocalProcessTerminalView + forkpty), extracted from
/// `TerminalManager` so both backends share the same protocol surface.
@MainActor
final class SwiftTermBackend: TerminalBackend {
    /// The SwiftTerm LocalProcessTerminalView (NSView with built-in PTY).
    private var terminalView: OutputAwareTerminalView?
    /// Stable placeholder so `view` never allocates per access.
    private var placeholder = OutputAwareTerminalView(frame: .zero)

    var view: NSView { terminalView ?? placeholder }

    var processPID: Int32 {
        terminalView?.process.shellPid ?? 0
    }

    // SwiftTerm's shellPid is the forkpty shell PID — already the stable
    // detection root.
    var detectionRootPID: Int32 {
        processPID
    }

    var isProcessRunning: Bool {
        guard let view = terminalView else { return false }
        return view.process.shellPid > 0
    }

    // MARK: - Callbacks

    var onFirstOutput: (() -> Void)?
    var onActivity: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onNotify: ((String, String) -> Void)?
    var onConnectError: ((String) -> Void)?

    /// Guards the process-exit callback so stale callbacks from previously
    /// terminated processes are ignored.
    private var processGeneration = 0

    // MARK: - Lifecycle

    @discardableResult
    func startAgent(executable: String, args: [String], env: [String], cwd: String) -> Bool {
        let view = makeView()

        // Register OSC 777 notification handler (ESC ] 777 ; notify ; <title> ; <body> ST)
        view.getTerminal().parser.oscHandlers[777] = { [weak self] data in
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            let parts = text.components(separatedBy: ";")
            guard parts.count >= 3, parts[0] == "notify" else { return }
            self?.onNotify?(parts[1], parts[2...].joined(separator: ";"))
        }
        // Register OSC 9 handler for simple attention notifications
        view.getTerminal().parser.oscHandlers[9] = { [weak self] data in
            guard let msg = String(bytes: data, encoding: .utf8), !msg.isEmpty else { return }
            self?.onNotify?("Session", msg)
        }

        return startProcess(view: view, executable: executable, args: args, env: env, cwd: cwd)
    }

    @discardableResult
    func startBash(cwd: String, env: [String]) -> Bool {
        let view = makeView()
        let zshPath = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: zshPath) else {
            let msg = "Shell not found at \(zshPath). This system may be missing zsh."
            onConnectError?(msg)
            return false
        }
        let ok = startProcess(view: view, executable: zshPath, args: ["-l"], env: env, cwd: cwd, scrollback: 200_000)
        if ok {
            // Start agent detection handled by TerminalManager after connectBash.
        }
        return ok
    }

    private func startProcess(view: OutputAwareTerminalView, executable: String, args: [String], env: [String], cwd: String, scrollback: Int = 50_000) -> Bool {
        view.startProcess(executable: executable, args: args, environment: env, currentDirectory: cwd)

        // SwiftTerm keeps shellPid == 0 silently when forkpty fails; don't
        // enter a fake "running" state in that case.
        guard view.process.shellPid > 0 else {
            let msg = "Failed to launch process. Check the executable and try again."
            onConnectError?(msg)
            return false
        }

        view.getTerminal().changeScrollback(scrollback)

        processGeneration += 1
        let gen = processGeneration
        view.processDelegate = Delegate(
            onExit: { [weak self] in
                DispatchQueue.main.async {
                    // Only fire exit callback for the current process generation.
                    guard let self, self.processGeneration == gen else { return }
                    self.onProcessExit?()
                }
            },
            onTitle: { [weak self] title in
                self?.onTitleChange?(title)
            }
        )

        self.terminalView = view
        return true
    }

    func terminate() {
        terminalView?.process.terminate()
        terminalView = nil
    }

    func detach() {
        // Keep terminalView alive so process keeps running. The exit callback
        // remains armed; the process is still alive after detach.
    }

    func reattach() {}

    // MARK: - I/O

    func sendInput(_ text: String) {
        terminalView?.send(txt: text)
    }

    // MARK: - Configuration

    func applyTheme(_ theme: TerminalTheme) {
        guard let view = terminalView else { return }
        view.nativeForegroundColor = theme.foregroundNSColor
        view.nativeBackgroundColor = theme.backgroundNSColor
        view.selectedTextBackgroundColor = theme.selectionNSColor
        view.caretColor = theme.cursorNSColor
        view.installColors(theme.ansiSwiftTermColors)
        view.needsDisplay = true
    }

    func setScrollback(_ lines: Int) {
        terminalView?.getTerminal().changeScrollback(lines)
    }

    // MARK: - View construction

    private func makeView() -> OutputAwareTerminalView {
        let view = OutputAwareTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let themeId = UserDefaults.standard.string(forKey: "terminalTheme") ?? "dracula"
        let theme = TerminalTheme.all.first { $0.id == themeId } ?? .dracula
        view.nativeForegroundColor = theme.foregroundNSColor
        view.nativeBackgroundColor = theme.backgroundNSColor
        view.selectedTextBackgroundColor = theme.selectionNSColor
        view.caretColor = theme.cursorNSColor
        view.installColors(theme.ansiSwiftTermColors)

        view.onFirstOutput = { [weak self] in
            DispatchQueue.main.async {
                self?.onFirstOutput?()
            }
        }
        view.onActivity = { [weak self] in
            DispatchQueue.main.async {
                self?.onActivity?()
            }
        }
        return view
    }
}

/// A LocalProcessTerminalView that notifies on first data received from the PTY.
private class OutputAwareTerminalView: LocalProcessTerminalView {
    var onFirstOutput: (() -> Void)?
    var onActivity: (() -> Void)?
    private var outputDetected = false

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if !outputDetected {
            outputDetected = true
            onFirstOutput?()
        }
        onActivity?()
        super.dataReceived(slice: slice)
    }
}

private class Delegate: NSObject, LocalProcessTerminalViewDelegate {
    let onExit: () -> Void
    let onTitle: (String) -> Void
    init(onExit: @escaping () -> Void, onTitle: @escaping (String) -> Void) {
        self.onExit = onExit
        self.onTitle = onTitle
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { onTitle(title) }
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) { onExit() }
}
