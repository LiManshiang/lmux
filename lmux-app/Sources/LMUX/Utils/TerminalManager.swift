import Foundation
import LMUXCore
import AppKit
import SwiftTerm
import UserNotifications
import Darwin

// File-scope (not class statics): TerminalManager is @MainActor, which in a
// Swift 5.7 toolchain would make class statics actor-isolated and unusable from
// the `nonisolated` methods below (`nonisolated(unsafe)` needs Swift 5.10+).
// File-scope globals aren't actor-isolated, and all access is serialized by the
// lock, which also keeps them safe under strict concurrency.

/// Short-lived cache of process command lines so repeated detection scans
/// (every 10s) don't shell out to ps for the same PIDs.
private var commandLineCache: [Int32: (String, TimeInterval)] = [:]
private let commandLineLock = NSLock()

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
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var memoryMB: Double?
    private var perfTimer: Timer?
    private var lastActivityTime: Date = Date()
    private var idleTimer: Timer?
    private var agentDetectionTimer: Timer?
    @Published private(set) var detectedAgentType: AgentType?
    /// Used to fall back to the project's most recent conversation when agent
    /// detection finds an agent without a --resume ID (e.g. claude launched
    /// fresh). Set by ContentViewModel when the manager is created.
    var agentSessionService: (any AgentSessionService)?
    /// Set when the last connect/connectBash attempt failed (e.g. agent
    /// binary missing). Shown in the terminal area instead of a blank view.
    @Published private(set) var connectErrorMessage: String?

    /// Clear a connection error shown in the terminal area.
    func clearConnectError() {
        connectErrorMessage = nil
    }

    init() {
        // Apply terminal theme changes live to any running terminal.
        NotificationCenter.default.addObserver(
            forName: .lmuxTerminalThemeChanged,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["themeId"] as? String else { return }
            self?.applyTheme(id)
        }
    }

    /// Apply a terminal theme to the running terminal view immediately.
    func applyTheme(_ themeId: String) {
        guard let theme = TerminalTheme.all.first(where: { $0.id == themeId }),
              let view = terminalView else { return }
        view.nativeForegroundColor = theme.foregroundNSColor
        view.nativeBackgroundColor = theme.backgroundNSColor
        view.selectedTextBackgroundColor = theme.selectionNSColor
        view.caretColor = theme.cursorNSColor
        view.installColors(theme.ansiSwiftTermColors)
        view.needsDisplay = true
    }

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

        // Build command (agent-specific behavior lives in its provider)
        let provider = agentType.provider
        connectErrorMessage = nil
        guard let agentPath = provider.findBinaryPath(),
              FileManager.default.isExecutableFile(atPath: agentPath) else {
            let msg = "\(agentType.displayName) executable '\(agentType.executableName)' not found. Install it or add its directory to PATH."
            connectErrorMessage = msg
            onConnectError?(msg)
            return
        }
        var args = provider.launchArgs
        if let id = cbcSessionID, !id.isEmpty {
            args.append(contentsOf: provider.resumeArgs(sessionID: id))
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

        // Agent-specific env/trust preparation (e.g. claude strips codebuddy
        // env vars and pre-accepts the workspace trust dialog).
        provider.prepareEnvironment(projectDir: projectDir, env: &parentEnv)

        let envList = parentEnv.map { "\($0.key)=\($0.value)" }

        // Start process
        view.startProcess(executable: agentPath, args: args, environment: envList, currentDirectory: projectDir)

        // SwiftTerm keeps shellPid == 0 silently when forkpty fails; don't
        // enter a fake "running" state in that case.
        guard view.process.shellPid > 0 else {
            let msg = "Failed to launch \(agentType.displayName). Check the executable and try again."
            connectErrorMessage = msg
            onConnectError?(msg)
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
        startPerfMonitoring()
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.processRunning else { return }
            let idle = Date().timeIntervalSince(self.lastActivityTime) > 3.0
            if self.isIdle != idle {
                self.isIdle = idle
            }
        }
    }

    /// Poll the shell process CPU/memory usage every few seconds so the
    /// sidebar can surface runaway agents.
    private func startPerfMonitoring() {
        perfTimer?.invalidate()
        perfTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, self.processRunning, self.processPID > 0 else { return }
            let pid = self.processPID
            Task.detached {
                let (cpu, mem) = Self.queryPerf(pid: pid)
                await MainActor.run {
                    self.cpuPercent = cpu
                    self.memoryMB = mem
                }
            }
        }
    }

    nonisolated private static func queryPerf(pid: Int32) -> (Double?, Double?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "%cpu=", "-o", "rss="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let parts = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isWhitespace) ?? []
            guard parts.count >= 2, let cpu = Double(parts[0]), let rss = Double(parts[1]) else {
                return (nil, nil)
            }
            return (cpu, rss / 1024) // rss is KB on macOS
        } catch {
            return (nil, nil)
        }
    }

    func disconnect() {
        idleTimer?.invalidate()
        idleTimer = nil
        perfTimer?.invalidate()
        perfTimer = nil
        cpuPercent = nil
        memoryMB = nil
        stopAgentDetection()
        connectErrorMessage = nil
        // Do NOT remove the restore binding here: disconnect() is also called
        // on app quit (terminateAllProcesses) and on user "Stop". The binding
        // tells the next launch which conversation to resume for this session
        // ("再进恢复"), so it must survive until the session itself is deleted
        // (releaseTerminalManager removes it).
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
            persistAgentDetection(
                agentType: result.agentType,
                cmdLineSessionID: result.cbcSessionID,
                notBefore: result.processStartTime,
                sessionID: sid,
                projectDir: detachProjectDir ?? NSHomeDirectory()
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
            let msg = "Shell not found at \(zshPath). This system may be missing zsh."
            connectErrorMessage = msg
            onConnectError?(msg)
            return
        }

        // Inherit full environment from parent process
        var parentEnv = ProcessInfo.processInfo.environment
        parentEnv["TERM"] = "xterm-256color"
        parentEnv["LANG"] = "en_US.UTF-8"
        let envList = parentEnv.map { "\($0.key)=\($0.value)" }

        view.startProcess(executable: zshPath, args: ["-l"], environment: envList, currentDirectory: projectDir)

        guard view.process.shellPid > 0 else {
            let msg = "Failed to launch the shell. Try again; if it persists, check system shell state."
            connectErrorMessage = msg
            onConnectError?(msg)
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
                    guard let self, let result, self.currentSessionID == sessionID else { return }
                    // Persist on agent-type change, or whenever the command line
                    // carries a resumable ID, or while the restore entry has no
                    // cbc yet. The last case is the retry window: a freshly
                    // launched agent may not have created its conversation file
                    // when detection first runs, so the cbc is still nil — we
                    // must keep trying so the bind eventually lands.
                    let alreadyBound = self.detectedAgentType == result.agentType
                        && result.cbcSessionID == nil
                        && SessionRestore.loadAll().first(where: { $0.sessionID == sessionID })?.cbcSessionID != nil
                    guard !alreadyBound else { return }
                    self.detectedAgentType = result.agentType
                    self.persistAgentDetection(
                        agentType: result.agentType,
                        cmdLineSessionID: result.cbcSessionID,
                        notBefore: result.processStartTime,
                        sessionID: sessionID,
                        projectDir: projectDir
                    )
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
                guard let self, let result, self.currentSessionID == sessionID else { return }
                self.detectedAgentType = result.agentType
                self.persistAgentDetection(
                    agentType: result.agentType,
                    cmdLineSessionID: result.cbcSessionID,
                    notBefore: result.processStartTime,
                    sessionID: sessionID,
                    projectDir: projectDir
                )
            }
        }
        Self.detectionQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !alreadyDetected else { return }
            let result = self.detectRunningAgent(shellPID: detectionPID)
            DispatchQueue.main.async { [weak self] in
                guard let self, let result, self.currentSessionID == sessionID else { return }
                self.detectedAgentType = result.agentType
                self.persistAgentDetection(
                    agentType: result.agentType,
                    cmdLineSessionID: result.cbcSessionID,
                    notBefore: result.processStartTime,
                    sessionID: sessionID,
                    projectDir: projectDir
                )
            }
        }
    }

    /// Persist an agent-detection result. The command line may lack a
    /// --resume ID (claude launched fresh), so the conversation is completed
    /// from the project's most recent history before saving — otherwise a
    /// restart would fall back to another session's conversation.
    private func persistAgentDetection(
        agentType: AgentType,
        cmdLineSessionID: String?,
        notBefore: Date?,
        sessionID: String,
        projectDir: String
    ) {
        // The session may have been disconnected/deleted while detection was
        // in flight; never re-save a removed session to restore.json.
        guard currentSessionID == sessionID else { return }
        let provider = agentType.provider
        guard let service = agentSessionService else {
            SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: cmdLineSessionID, agentType: agentType, launchMode: .agent)
            return
        }
        Task {
            let cbc = await provider.detectionSessionID(
                cmdLineSessionID: cmdLineSessionID,
                allowHistoryLookup: true,
                projectDir: projectDir,
                notBefore: notBefore,
                service: service
            )
            SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: cbc, agentType: agentType, launchMode: .agent)
        }
    }

    private func stopAgentDetection() {
        agentDetectionTimer?.invalidate()
        agentDetectionTimer = nil
        detectedAgentType = nil
    }

    /// Walk child processes of `shellPID` to find known agent executables.
    /// Runs on background queue; does not access main-actor state.
    nonisolated private func detectRunningAgent(shellPID: Int32) -> (agentType: AgentType, cbcSessionID: String?, processStartTime: Date?)? {
        // Check all descendants (not just direct children) in case agent runs in a subshell.
        guard let allPIDs = getDescendantPIDs(of: shellPID) else { return nil }

        var best: (AgentType, String?)? = nil
        var bestPriority = -1
        var bestStart: Date?
        for pid in allPIDs {
            let cmdLine = getCommandLine(of: pid) ?? ""
            for agent in AgentType.allCases {
                guard let match = agent.provider.detectProcess(cmdLine: cmdLine) else { continue }
                // Highest detection priority wins (e.g. a leftover codebuddy
                // process must not shadow the claude the user launched).
                if agent.detectionPriority > bestPriority {
                    best = (agent, match.sessionID)
                    bestPriority = agent.detectionPriority
                    bestStart = getProcessStartTime(pid: pid)
                }
            }
        }
        guard let best else { return nil }
        return (agentType: best.0, cbcSessionID: best.1, processStartTime: bestStart)
    }

    /// Start time of a process (from `ps -o lstart`), used to scope history
    /// lookup to conversations created after the agent launch.
    nonisolated private func getProcessStartTime(pid: Int32) -> Date? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "lstart="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            let date = formatter.date(from: text)
            if date == nil {
                // Fall back to `ps -o lstart` with the default output even if
                // trimming removed a trailing tab; some locale/ps versions
                // emit a trailing tab after the year.
                let alt = text.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                return formatter.date(from: alt)
            }
            return date
        } catch {
            return nil
        }
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
        commandLineLock.lock()
        defer { commandLineLock.unlock() }
        if let cached = commandLineCache[pid], Date().timeIntervalSince1970 - cached.1 < 5 {
            // Guard against PID reuse: only trust the cache while the process
            // still exists.
            if kill(pid, 0) == 0 {
                return cached.0
            }
            commandLineCache.removeValue(forKey: pid)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        var result: String?
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            result = nil
        }
        if let result {
            commandLineCache[pid] = (result, Date().timeIntervalSince1970)
        }
        return result
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
