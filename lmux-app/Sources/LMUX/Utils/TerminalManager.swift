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
    /// Called on main actor when starting a process fails (e.g. executable not found).
    var onConnectError: ((String) -> Void)?

    /// The SwiftTerm LocalProcessTerminalView (NSView with built-in PTY)
    private(set) var terminalView: LocalProcessTerminalView?

    private var currentSessionID: String?
    private var detachProjectDir: String?
    private var processGeneration: Int = 0
    private(set) var processStartTime: Date?
    private(set) var processPID: Int32 = 0
    private var lastActivityTime: Date = Date()
    private var idleTimer: Timer?
    private var agentDetectionTimer: Timer?
    @Published private(set) var detectedAgentType: AgentType?

    /// Connect by spawning an agent directly via SwiftTerm's forkpty.
    func connect(sessionID: String, projectDir: String, cbcSessionID: String?, agentType: AgentType = .codebuddy) {
        // restore and connectToSession can race (both call connect for the
        // same session at startup); restarting would kill the just-launched
        // process. If this session is already running, reuse it.
        if currentSessionID == sessionID, processRunning, terminalView != nil {
            isConnected = true
            startIdleTimer()
            return
        }
        disconnect()

        currentSessionID = sessionID
        detachProjectDir = projectDir

        // ... same terminal setup ...
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
            DispatchQueue.main.async {
                self?.onFirstOutput?()
            }
        }
        view.onActivity = { [weak self] in
            DispatchQueue.main.async {
                self?.lastActivityTime = Date()
            }
        }

        // Build command
        if agentType == .claude {
            // claude shows a workspace trust dialog on first run in a
            // directory; pre-accept it so it doesn't block the embedded
            // terminal (the dialog can't be answered there).
            SessionRestore.acceptClaudeTrust(directory: projectDir)
        }
        let agentPath = findAgentPath(name: agentType.executableName)
        guard FileManager.default.isExecutableFile(atPath: agentPath) else {
            onConnectError?("Agent executable not found: \(agentPath)")
            return
        }
        var args = agentType.launchArgs
        if let id = cbcSessionID, !id.isEmpty {
            args.append(contentsOf: agentType.resumeArgs(sessionID: id))
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
        let agentDir = URL(fileURLWithPath: agentPath).deletingLastPathComponent().path
        if !pathEnv.contains(agentDir) { pathEnv = "\(agentDir):\(pathEnv)" }
        parentEnv["PATH"] = pathEnv

        if agentType == .claude {
            // The app inherits CLAUDE_*/CODEBUDDY_* variables from codebuddy
            // (notably CLAUDE_SESSION_ID pointing at a codebuddy conversation).
            // claude sees those and refuses to render its TUI (it only emits
            // the setup sequence). Strip them for claude.
            parentEnv = parentEnv.filter { key, _ in
                !key.hasPrefix("CLAUDE_") && !key.hasPrefix("CODEBUDDY")
            }
        }

        let envList = parentEnv.map { "\($0.key)=\($0.value)" }

        // Start process
        view.startProcess(executable: agentPath, args: args, environment: envList, currentDirectory: projectDir)

        // SwiftTerm keeps shellPid == 0 silently when forkpty fails; don't
        // enter a fake "running" state in that case.
        guard view.process.shellPid > 0 else {
            onConnectError?("Failed to launch \(agentType.executableName)")
            return
        }

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

        // Keep enough scrollback for a full day of conversation.
        view.getTerminal().changeScrollback(50_000)

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
        SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: cbcSessionID, agentType: agentType, launchMode: .agent)
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.processRunning else { return }
            let idle = Date().timeIntervalSince(self.lastActivityTime) > 3.0
            if self.isIdle != idle {
                self.isIdle = idle
            }
        }
    }

    func disconnect() {
        idleTimer?.invalidate()
        idleTimer = nil
        stopAgentDetection()
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
        // If an agent is running inside the shell right now, record it so the
        // next launch can resume it (the periodic detection may have missed it
        // if the user started codebuddy shortly before switching away).
        if processPID > 0,
           detectedAgentType == nil,
           let result = detectRunningAgent(shellPID: processPID),
           let sid = currentSessionID {
            detectedAgentType = result.agentType
            SessionRestore.save(
                sessionID: sid,
                projectDir: detachProjectDir ?? NSHomeDirectory(),
                cbcSessionID: result.cbcSessionID,
                agentType: result.agentType,
                launchMode: .agent
            )
        }
        isConnected = false
        // Keep the idle timer running: the process is still alive after
        // detach, so its idle/running state must keep updating in the
        // sidebar. startIdleTimer() invalidates+reschedules on reattach.
        // Stop the agent-detection timer so it doesn't linger after switching
        // sessions; it restarts on the next connectBash(). detectedAgentType
        // is preserved for reattach.
        agentDetectionTimer?.invalidate()
        agentDetectionTimer = nil
        // Keep terminalView alive so process keeps running
    }

    /// Re-attach: terminalView and process are still alive, just mark connected.
    func reattach() {
        guard terminalView != nil else { return }
        isConnected = true
        startIdleTimer()
    }

    /// Formatted elapsed time since process started, or nil if not running.
    var formattedElapsed: String? {
        guard let start = processStartTime, processRunning else { return nil }
        let elapsed = Int(Date().timeIntervalSince(start))
        if elapsed < 60 { return "\(elapsed)s" }
        if elapsed < 3600 { return "\(elapsed / 60)m \(elapsed % 60)s" }
        return "\(elapsed / 3600)h \((elapsed % 3600) / 60)m"
    }

    /// Send text into the terminal as if the user typed it (used by file drop).
    func sendInput(_ text: String) {
        guard processRunning else { return }
        terminalView?.send(txt: text)
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

    /// Connect a bash/zsh terminal in the given directory (for new sessions).
    func connectBash(sessionID: String, projectDir: String, agentType: AgentType) {
        disconnect()

        currentSessionID = sessionID
        detachProjectDir = projectDir

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
                self?.lastActivityTime = Date()
            }
        }

        let zshPath = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: zshPath) else {
            onConnectError?("Shell not found: \(zshPath)")
            return
        }

        // Inherit full environment from parent process
        var parentEnv = ProcessInfo.processInfo.environment
        parentEnv["TERM"] = "xterm-256color"
        parentEnv["LANG"] = "en_US.UTF-8"
        let envList = parentEnv.map { "\($0.key)=\($0.value)" }

        view.startProcess(executable: zshPath, args: ["-l"], environment: envList, currentDirectory: projectDir)

        guard view.process.shellPid > 0 else {
            onConnectError?("Failed to launch shell")
            return
        }
        view.getTerminal().changeScrollback(200_000)

        self.terminalView = view
        isConnected = true
        processRunning = true
        processStartTime = Date()
        processPID = view.process.shellPid
        lastActivityTime = Date()
        startIdleTimer()

        // Persist for session restore
        SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: nil, agentType: agentType, launchMode: .bash)

        // Start agent detection: periodically check what child processes the user
        // runs inside the bash terminal so we can restore the correct agent type.
        startAgentDetection(sessionID: sessionID, projectDir: projectDir)
    }

    // MARK: - Agent Detection

    /// Background queue for agent detection subprocess calls (pgrep/ps).
    private static let detectionQueue = DispatchQueue(label: "lmux.agent-detection", qos: .utility)

    /// Start periodically checking the shell's child processes for known agent executables.
    private func startAgentDetection(sessionID: String, projectDir: String) {
        stopAgentDetection()
        let pid = self.processPID
        guard pid > 0 else { return }

        agentDetectionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self, self.processRunning, self.processPID > 0 else { return }
            let currentPID = self.processPID
            Self.detectionQueue.async { [weak self] in
                guard let self else { return }
                let result = self.detectRunningAgent(shellPID: currentPID)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let result else { return }
                    guard result.agentType != self.detectedAgentType || result.cbcSessionID != nil else { return }
                    self.detectedAgentType = result.agentType
                    SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: result.cbcSessionID, agentType: result.agentType, launchMode: .agent)
                }
            }
        }
        // Fire immediately, then again at 3s and 10s for quick detection (agent might not be running yet).
        agentDetectionTimer?.fire()

        let detectionPID = self.processPID
        let alreadyDetected = self.detectedAgentType != nil

        Self.detectionQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !alreadyDetected else { return }
            let result = self.detectRunningAgent(shellPID: detectionPID)
            DispatchQueue.main.async { [weak self] in
                guard let self, let result else { return }
                self.detectedAgentType = result.agentType
                SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: result.cbcSessionID, agentType: result.agentType, launchMode: .agent)
            }
        }
        Self.detectionQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !alreadyDetected else { return }
            let result = self.detectRunningAgent(shellPID: detectionPID)
            DispatchQueue.main.async { [weak self] in
                guard let self, let result else { return }
                self.detectedAgentType = result.agentType
                SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: result.cbcSessionID, agentType: result.agentType, launchMode: .agent)
            }
        }
    }

    private func stopAgentDetection() {
        agentDetectionTimer?.invalidate()
        agentDetectionTimer = nil
        detectedAgentType = nil
    }

    /// Walk child processes of `shellPID` to find known agent executables.
    /// Runs on background queue; does not access main-actor state.
    nonisolated private func detectRunningAgent(shellPID: Int32) -> (agentType: AgentType, cbcSessionID: String?)? {
        // Check all descendants (not just direct children) in case agent runs in a subshell.
        guard let allPIDs = getDescendantPIDs(of: shellPID) else { return nil }

        var codebuddyMatch: (AgentType, String?)? = nil
        for pid in allPIDs {
            // Check the command line of each child.
            let cmdLine = getCommandLine(of: pid) ?? ""
            let lower = cmdLine.lowercased()

            // Detect Claude. Claude wins when present: a leftover codebuddy
            // process must not shadow the agent the user actually launched.
            if lower.contains("claude") && !lower.contains("claudecode") {
                return (.claude, extractSessionID(from: cmdLine, agent: "claude"))
            }
            // Detect CodeBuddy.
            if (lower.contains("codebuddy-code") || lower.contains("codebuddy")) && codebuddyMatch == nil {
                codebuddyMatch = (.codebuddy, extractSessionID(from: cmdLine, agent: "codebuddy"))
            }
        }

        return codebuddyMatch
    }

    /// Extract the resume/session ID from an agent command line.
    nonisolated private func extractSessionID(from cmdLine: String, agent: String) -> String? {
        // codebuddy: codebuddy-code --permission-mode auto --resume <UUID>
        //            codebuddy-code --permission-mode auto --session-id <UUID>
        // claude:     claude --dangerously-skip-permissions --resume <UUID>
        let components = cmdLine.components(separatedBy: " ")
        for i in 0..<(components.count - 1) {
            let arg = components[i]
            if arg == "--session-id" || arg == "--resume"
                || arg.hasPrefix("--session-id=") || arg.hasPrefix("--resume=") {
                if arg.contains("=") {
                    return arg.components(separatedBy: "=").last
                } else {
                    return components[i + 1]
                }
            }
        }
        return nil
    }

    /// Returns PIDs of all descendants (children recursively) of the given parent PID.
    nonisolated private func getDescendantPIDs(of parentPID: Int32) -> [Int32]? {
        var all: [Int32] = []
        var queue = [parentPID]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard let children = getChildPIDs(of: current) else { continue }
            all.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return all.isEmpty ? nil : all
    }

    /// Returns PIDs of direct children of the given parent PID.
    nonisolated private func getChildPIDs(of parentPID: Int32) -> [Int32]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(parentPID)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(separator: "\n").compactMap { Int32($0) }
        } catch {
            return nil
        }
    }

    /// Returns the full command line of a process by PID.
    nonisolated private func getCommandLine(of pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static var agentPathCache: [String: String] = [:]

    private func findAgentPath(name: String) -> String {
        // Return cached path if still valid.
        if let cached = Self.agentPathCache[name],
           FileManager.default.isExecutableFile(atPath: cached) {
            return cached
        }

        // 1. Search PATH first
        var nonArm64Fallback: String?
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        for dir in pathDirs {
            let p = "\(dir)/\(name)"
            guard FileManager.default.isExecutableFile(atPath: p) else { continue }
            if name == "claude" {
                // Skip broken postinstall stubs; prefer a native arm64 binary
                // over a Rosetta x86_64 one (x86 claude warns about AVX and
                // can crash).
                if Self.isArm64ClaudeBinary(p) {
                    Self.agentPathCache[name] = p
                    return p
                }
                if Self.isRealClaudeBinary(p), nonArm64Fallback == nil {
                    nonArm64Fallback = p
                }
            } else {
                Self.agentPathCache[name] = p
                return p
            }
        }
        if let nonArm64Fallback {
            Self.agentPathCache[name] = nonArm64Fallback
            return nonArm64Fallback
        }

        // 2. Try common fixed paths
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) {
                Self.agentPathCache[name] = p
                return p
            }
        }

        // 3. Search nvm installations across mounted volumes
        var nonArm64Fallback2: String?
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for vol in volumes where vol != "Macintosh HD" && !vol.hasPrefix(".") {
            let nvmBase = "/Volumes/\(vol)/OpenSource/nvm/versions/node"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
                for entry in entries {
                    let p = "\(nvmBase)/\(entry)/bin/\(name)"
                    guard FileManager.default.isExecutableFile(atPath: p) else { continue }
                    if name == "claude" {
                        if Self.isArm64ClaudeBinary(p) {
                            Self.agentPathCache[name] = p
                            return p
                        }
                        if Self.isRealClaudeBinary(p), nonArm64Fallback2 == nil {
                            nonArm64Fallback2 = p
                        }
                    } else {
                        Self.agentPathCache[name] = p
                        return p
                    }
                }
            }
        }
        if let nonArm64Fallback2 {
            Self.agentPathCache[name] = nonArm64Fallback2
            return nonArm64Fallback2
        }

        // 4. Check NVM_DIR from environment
        let env = ProcessInfo.processInfo.environment
        if let nvmDir = env["NVM_DIR"] {
            let p = "\(nvmDir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) {
                if name == "claude" && !Self.isRealClaudeBinary(p) {
                    // fall through
                } else {
                    Self.agentPathCache[name] = p
                    return p
                }
            }
        }

        let fallback = "/opt/homebrew/bin/\(name)"
        Self.agentPathCache[name] = fallback
        return fallback
    }

    /// claude is a symlink to .../claude.exe. A failed npm postinstall leaves
    /// a ~500-byte stub that errors at launch ("native binary not installed");
    /// only accept a real native binary (>1MB).
    private static func isRealClaudeBinary(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              let size = attrs[.size] as? Int else {
            return false
        }
        return size > 1_000_000
    }

    /// True when claude.exe is a native arm64 Mach-O (or a universal binary).
    /// x86_64 builds run under Rosetta and warn about AVX / can crash.
    private static func isArm64ClaudeBinary(_ path: String) -> Bool {
        guard isRealClaudeBinary(path) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: resolved)) else {
            return false
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 8)
        guard data.count >= 8 else { return false }
        let b = [UInt8](data)
        // Mach-O 64-bit magic: 0xFEEDFACF (big-endian on disk) / 0xCFFAEDFE (LE).
        let magic = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        if magic == 0xCAFEBABE { return true } // universal binary
        guard magic == 0xFEEDFACF || magic == 0xCFFAEDFE else { return false }
        let cputype = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        return cputype == 0x0100_000C // CPU_TYPE_ARM64
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
    init(onExit: @escaping () -> Void) { self.onExit = onExit }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) { onExit() }
}
