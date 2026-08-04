import Foundation
import AppKit
import SwiftTerm
import UserNotifications

@MainActor
class TerminalManager: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var processRunning: Bool = false
    @Published var isIdle: Bool = true

    /// Called on main actor when the codebuddy-code process exits.
    var onProcessExit: (() -> Void)?
    /// Called on main actor when codebuddy-code produces first terminal output.
    var onFirstOutput: (() -> Void)?

    /// The SwiftTerm LocalProcessTerminalView (NSView with built-in PTY)
    private(set) var terminalView: LocalProcessTerminalView?

    private var currentSessionID: String?
    private var processGeneration: Int = 0
    private(set) var processStartTime: Date?
    private(set) var processPID: Int32 = 0
    private var lastActivityTime: Date = Date()
    private var idleTimer: Timer?

    /// Connect by spawning codebuddy-code directly via SwiftTerm's forkpty.
    func connect(sessionID: String, projectDir: String, cbcSessionID: String?) {
        disconnect()

        currentSessionID = sessionID

        let view = OutputAwareTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // Apply selected theme
        let themeId = UserDefaults.standard.string(forKey: "terminalTheme") ?? "dracula"
        let theme = TerminalTheme.all.first { $0.id == themeId } ?? .dracula
        view.nativeForegroundColor = theme.foregroundNSColor
        view.nativeBackgroundColor = theme.backgroundNSColor
        view.selectedTextBackgroundColor = theme.selectionNSColor
        view.caretColor = theme.cursorNSColor
        view.installColors(theme.ansiSwiftTermColors)
        view.onFirstOutput = { [weak self] in
            self?.onFirstOutput?()
        }
        view.onActivity = { [weak self] in
            self?.lastActivityTime = Date()
            self?.isIdle = false
        }

        // Build command
        let cbcPath = findCodeBuddyPath()
        var args = ["--permission-mode", "auto", "-y"]
        if let id = cbcSessionID, !id.isEmpty {
            args.append(contentsOf: ["--session-id", id])
        }

        // Build environment
        let home = NSHomeDirectory()
        var parentEnv = ProcessInfo.processInfo.environment
        parentEnv["TERM"] = "xterm-256color"
        parentEnv["LANG"] = "en_US.UTF-8"
        parentEnv["HOME"] = home

        // Fix PATH
        var pathEnv = parentEnv["PATH"] ?? "/usr/bin:/bin"
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] {
            if !pathEnv.contains(p) { pathEnv = "\(p):\(pathEnv)" }
        }
        let cbcDir = URL(fileURLWithPath: cbcPath).deletingLastPathComponent().path
        if !pathEnv.contains(cbcDir) { pathEnv = "\(cbcDir):\(pathEnv)" }
        parentEnv["PATH"] = pathEnv

        let envList = parentEnv.map { "\($0.key)=\($0.value)" }

        // Start process
        view.startProcess(executable: cbcPath, args: args, environment: envList, currentDirectory: projectDir)

        // Register OSC 777 notification handler (ESC ] 777 ; notify ; <title> ; <body> ST)
        view.getTerminal().parser.oscHandlers[777] = { [weak self] data in
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            let parts = text.components(separatedBy: ";")
            guard parts.count >= 3, parts[0] == "notify" else { return }
            self?.sendOSCNotification(title: parts[1], body: parts[2...].joined(separator: ";"))
        }

        // Register OSC 9 handler for simple attention notifications
        view.getTerminal().parser.oscHandlers[9] = { [weak self] data in
            guard let msg = String(bytes: data, encoding: .utf8), !msg.isEmpty else { return }
            self?.sendOSCNotification(title: "Session", body: msg)
        }

        // Unlimited scrollback for full session history
        view.getTerminal().changeScrollback(1_000_000)

        processGeneration += 1
        let gen = processGeneration

        // Track process exit
        view.processDelegate = Delegate { [weak self] in
            DispatchQueue.main.async {
                // Only fire exit callback for the current process generation,
                // not stale callbacks from previously-terminated processes.
                guard self?.processGeneration == gen else { return }
                self?.isConnected = false
                self?.processRunning = false
                self?.onProcessExit?()
            }
        }

        self.terminalView = view
        isConnected = true
        processRunning = true
        processStartTime = Date()
        processPID = view.process.shellPid
        lastActivityTime = Date()
        startIdleTimer()

        // Persist for session restore on app restart
        SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: cbcSessionID)
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.processRunning else { return }
            if Date().timeIntervalSince(self.lastActivityTime) > 3.0 {
                self.isIdle = true
            }
        }
    }

    func disconnect() {
        idleTimer?.invalidate()
        idleTimer = nil
        if let sid = currentSessionID {
            SessionRestore.remove(sessionID: sid)
        }
        terminalView?.process.terminate()
        terminalView = nil
        currentSessionID = nil
        isConnected = false
        processRunning = false
        processStartTime = nil
        processPID = 0
    }

    /// Detach without killing: disconnect UI but keep process running.
    /// LocalProcessTerminalView's process continues because we don't call terminate().
    func detach() {
        isConnected = false
        // Keep terminalView alive so process keeps running
    }

    /// Re-attach: terminalView and process are still alive, just mark connected.
    func reattach() {
        guard terminalView != nil else { return }
        isConnected = true
    }

    /// Formatted elapsed time since process started, or nil if not running.
    var formattedElapsed: String? {
        guard let start = processStartTime, processRunning else { return nil }
        let elapsed = Int(Date().timeIntervalSince(start))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m \(elapsed % 60)s" }
        return "\(elapsed / 3600)h \((elapsed % 3600) / 60)m"
    }

    /// Whether the session needs user attention (task completed in background).
    var needsAttention: Bool {
        !isConnected && !processRunning && terminalView != nil
    }

    private func sendOSCNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "lmux-osc-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func findCodeBuddyPath() -> String {
        // 1. Search PATH first
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        for dir in pathDirs {
            let p = "\(dir)/codebuddy-code"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        // 2. Try common fixed paths
        let candidates = [
            "/opt/homebrew/bin/codebuddy-code",
            "/usr/local/bin/codebuddy-code",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        // 3. Search nvm installations across mounted volumes
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for vol in volumes where vol != "Macintosh HD" && !vol.hasPrefix(".") {
            let nvmBase = "/Volumes/\(vol)/OpenSource/nvm/versions/node"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
                for entry in entries {
                    let p = "\(nvmBase)/\(entry)/bin/codebuddy-code"
                    if FileManager.default.isExecutableFile(atPath: p) { return p }
                }
            }
        }

        // 4. Check NVM_DIR from environment
        let env = ProcessInfo.processInfo.environment
        if let nvmDir = env["NVM_DIR"] {
            let p = "\(nvmDir)/codebuddy-code"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        return "/opt/homebrew/bin/codebuddy-code"
    }
}

/// A LocalProcessTerminalView that notifies on first data received from the PTY.
/// Also filters CSI 3 J (clear scrollback) escape sequences to preserve the
/// entire conversation history in the terminal buffer.
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

        // Strip CSI 3 J (clear scrollback) to preserve conversation history.
        // This is the escape sequence: ESC [ 3 J = 0x1B 0x5B 0x33 0x4A
        var data = Array(slice)
        var i = 0
        while i < data.count {
            if i + 3 < data.count,
               data[i] == 0x1B, data[i + 1] == 0x5B,
               data[i + 2] == 0x33, data[i + 3] == 0x4A {
                data.removeSubrange(i..<(i + 4))
            } else {
                i += 1
            }
        }

        if !data.isEmpty {
            super.dataReceived(slice: data[...])
        }
    }
}

private class Delegate: NSObject, LocalProcessTerminalViewDelegate {
    let onExit: () -> Void
    init(onExit: @escaping () -> Void) { self.onExit = onExit }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) { onExit() }
}
