import Foundation
import LMUXCore
import AppKit
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

    /// Called on main actor when the agent process exits.
    var onProcessExit: (() -> Void)?
    /// Called on main actor when the agent produces first terminal output.
    var onFirstOutput: (() -> Void)?
    /// Called on main actor when starting a process fails (e.g. executable not found).
    var onConnectError: ((String) -> Void)?

    /// The active rendering backend (SwiftTerm or Ghostty). Nil while detached
    /// or before the first connect; the instance is preserved across detach.
    private(set) var backend: TerminalBackend?

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
    /// Conversation ID resolved once an agent is detected in the shell. Lets
    /// the UI show context usage for the *right* conversation instead of
    /// falling back to "most recent in project" (which can point at another
    /// session).
    @Published private(set) var detectedCBCSessionID: String?
    /// Set when the last connect/connectBash attempt failed (e.g. agent
    /// binary missing). Shown in the terminal area instead of a blank view.
    @Published private(set) var connectErrorMessage: String?

    /// Service used to resolve the conversation ID for a freshly launched
    /// agent (e.g. claude without a --resume ID). Set by ContentViewModel
    /// when the manager is created.
    var agentSessionService: (any AgentSessionService)?
    /// Fired when an agent is detected in the shell. ContentViewModel uses it
    /// to publish detection state globally so list rows render the context
    /// usage line even when they are not observing this manager.
    var onAgentDetected: ((AgentType, String?) -> Void)?

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
        guard let theme = TerminalTheme.all.first(where: { $0.id == themeId }) else { return }
        backend?.applyTheme(theme)
    }

    /// Apply the currently selected theme from preferences. Called when a new
    /// backend is created (connect/connectBash) so a freshly connected session
    /// inherits the user's theme instead of the default.
    private func applyCurrentTheme() {
        let themeId = UserDefaults.standard.string(forKey: "terminalTheme")
            ?? "dracula"
        guard let theme = TerminalTheme.all.first(where: { $0.id == themeId }) else { return }
        backend?.applyTheme(theme)
    }

    /// Connect by spawning an agent via the active backend.
    func connect(sessionID: String, projectDir: String, cbcSessionID: String?, agentType: AgentType = .codebuddy) {
        // restore and connectToSession can race (both call connect for the
        // same session at startup); restarting would kill the just-launched
        // process. If this session is already running, reuse it.
        if currentSessionID == sessionID, processRunning, backend != nil {
            isConnected = true
            startIdleTimer()
            return
        }
        disconnect()

        currentSessionID = sessionID
        detachProjectDir = projectDir

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
        // Fresh launch: NO --session-id. An agent started without a resumable
        // ID creates its own brand-new conversation (both codebuddy and claude
        // do this), and find-session binds this session to that exact file. A
        // lmux-assigned --session-id would create a decoy conversation that
        // find-session prefers forever, so a user who then /resume's to a real
        // conversation would never be tracked.

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

        // Create the backend and wire callbacks.
        let backend = TerminalBackendFactory.make()
        self.backend = backend
        wireCallbacks(backend: backend)

        let ok = backend.startAgent(
            executable: agentPath,
            args: args,
            env: envList,
            cwd: projectDir
        )
        guard ok else {
            // SwiftTerm: startAgent returns false only when forkpty fails and
            // already called onConnectError. Ghostty is async — returns true.
            disconnect()
            return
        }

        processGeneration += 1
        let gen = processGeneration

        // Track process exit
        backend.onProcessExit = { [weak self] in
            DispatchQueue.main.async {
                // Only fire exit callback for the current process generation,
                // not stale callbacks from previously-terminated processes.
                guard let self, self.processGeneration == gen else { return }
                self.isConnected = false
                self.processRunning = false
                self.onProcessExit?()
            }
        }

        // Register OSC 777/9 notification via backend.onNotify (Ghostty) or
        // its internal handlers (SwiftTerm). Both funnel to this callback.
        backend.onNotify = { [weak self] title, body in
            self?.sendOSCNotification(title: title, body: body)
        }

        isConnected = true
        processRunning = true
        processStartTime = Date()
        processPID = backend.processPID
        lastActivityTime = Date()
        startIdleTimer()

        // Inherit the user's selected theme for this new backend.
        applyCurrentTheme()

        // Persist for session restore on app restart
        SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: cbcSessionID, agentType: agentType, launchMode: .agent)

        // Start agent detection here too (not just connectBash): a user can
        // `/resume <id>` inside the launched agent, and detection is what
        // binds the new live conversation to this session so a restart
        // restores it automatically.
        startAgentDetection(sessionID: sessionID, projectDir: projectDir)
    }

    private func wireCallbacks(backend: TerminalBackend) {
        backend.onFirstOutput = { [weak self] in
            DispatchQueue.main.async {
                self?.onFirstOutput?()
            }
        }
        backend.onActivity = { [weak self] in
            DispatchQueue.main.async {
                self?.lastActivityTime = Date()
            }
        }
        backend.onConnectError = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                // Ghostty reports spawn failure asynchronously (surface closes
                // before the process ever produced a PID). Roll back the
                // optimistic running state so the ConnectionErrorView shows.
                if self.processRunning, !backend.isProcessRunning {
                    self.isConnected = false
                    self.processRunning = false
                    self.idleTimer?.invalidate()
                    self.idleTimer = nil
                }
                self.connectErrorMessage = message
                self.onConnectError?(message)
            }
        }
    }

    private func startIdleTimer() {
        startPerfMonitoring()
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, self.processRunning else { return }
            // Sync PID from the backend (Ghostty's surface is created
            // asynchronously once its view attaches; SwiftTerm's is immediate).
            if let backend = self.backend, backend.processPID != self.processPID, backend.processPID > 0 {
                self.processPID = backend.processPID
            }
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
        backend?.terminate()
        backend = nil
        currentSessionID = nil
        isConnected = false
        processRunning = false
        processStartTime = nil
        processPID = 0
    }

    /// Detach without killing: disconnect UI but keep process running.
    /// The backend's view/process continues because we don't call terminate().
    func detach() {
        // If an agent is running inside the shell right now, record it so the
        // next launch can resume it (the periodic detection may have missed it
        // if the user started the agent shortly before switching away).
        let rootPID = backend?.detectionRootPID ?? 0
        if rootPID > 0,
           detectedAgentType == nil,
           let result = detectRunningAgent(shellPID: rootPID),
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
        // sidebar. StartIdleTimer() invalidates+reschedules on reattach.
        // Stop the agent-detection timer so it doesn't linger after switching
        // sessions; it restarts on the next connectBash(). detectedAgentType
        // is preserved for reattach.
        agentDetectionTimer?.invalidate()
        agentDetectionTimer = nil
        // Keep backend alive so process keeps running
        backend?.detach()
    }

    /// Re-attach: backend and process are still alive, just mark connected.
    func reattach() {
        guard backend != nil else { return }
        backend?.reattach()
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
        backend?.sendInput(text)
    }

    /// Whether the session needs user attention (task completed in background).
    var needsAttention: Bool {
        !isConnected && !processRunning && backend != nil
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

        // Build environment (inherit full environment from parent process)
        var parentEnv = ProcessInfo.processInfo.environment
        parentEnv["TERM"] = "xterm-256color"
        parentEnv["LANG"] = "en_US.UTF-8"
        let envList = parentEnv.map { "\($0.key)=\($0.value)" }

        let backend = TerminalBackendFactory.make()
        self.backend = backend
        wireCallbacks(backend: backend)

        guard backend.startBash(cwd: projectDir, env: envList) else {
            // Backend already reported the error via onConnectError.
            disconnect()
            return
        }

        processGeneration += 1
        let gen = processGeneration
        backend.onProcessExit = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.processGeneration == gen else { return }
                self.isConnected = false
                self.processRunning = false
                self.onProcessExit?()
            }
        }
        backend.onNotify = { [weak self] title, body in
            self?.sendOSCNotification(title: title, body: body)
        }

        // Apply scrollback after the surface has settled. Applying it
        // synchronously here (right after surface creation) crashes ghostty's
        // update_config path (onig_free / arena allocator) when a fresh
        // surface is pushed a new config immediately — the surface's derived
        // config isn't ready yet. Deferring keeps the scrollback without the
        // crash.
        let scrollbackBackend = self.backend
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.backend === scrollbackBackend else { return }
            scrollbackBackend?.setScrollback(200_000)
        }

        isConnected = true
        processRunning = true
        processStartTime = Date()
        processPID = backend.processPID
        lastActivityTime = Date()
        startIdleTimer()

        // Persist for session restore
        SessionRestore.save(sessionID: sessionID, projectDir: projectDir, cbcSessionID: nil, agentType: agentType, launchMode: .bash)

        // Inherit the user's selected theme for this new backend.
        applyCurrentTheme()

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
        // NOTE: do NOT bail when detectionRootPID is 0. Ghostty creates its
        // surface asynchronously, so the shell PID may not be known yet — the
        // timer below re-reads it every tick and starts working as soon as it
        // appears. Bailing here would silently disable agent detection.

        // Poll at 3s so a freshly launched agent (and its context-usage row)
        // shows up within a few seconds instead of after a 10s wait.
        agentDetectionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.processRunning, self.processPID > 0 else { return }
            let currentPID = self.backend?.detectionRootPID ?? 0
            guard currentPID > 0 else { return }
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
                    // Only an explicit `--resume` ID is authoritative. A
                    // `--session-id` (lmux's fresh-launch isolation) or a
                    // fresh launch must go through find-session so the
                    // binding tracks the conversation the user is actually
                    // using (they may /resume away immediately).
                    cmdLineSessionID: result.isResume ? result.cbcSessionID : nil,
                    notBefore: result.processStartTime,
                    sessionID: sessionID,
                    projectDir: projectDir
                )
                }
            }
        }
        // Fire immediately, then again at 3s and 10s for quick detection (agent might not be running yet).
        agentDetectionTimer?.fire()

        let alreadyDetected = self.detectedAgentType != nil

        Self.detectionQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !alreadyDetected, let pid = self.backend?.detectionRootPID, pid > 0 else { return }
            let result = self.detectRunningAgent(shellPID: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, let result, self.currentSessionID == sessionID else { return }
                self.detectedAgentType = result.agentType
                self.persistAgentDetection(
                    agentType: result.agentType,
                    cmdLineSessionID: result.isResume ? result.cbcSessionID : nil,
                    notBefore: result.processStartTime,
                    sessionID: sessionID,
                    projectDir: projectDir
                )
            }
        }
        Self.detectionQueue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !alreadyDetected, let pid = self.backend?.detectionRootPID, pid > 0 else { return }
            let result = self.detectRunningAgent(shellPID: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, let result, self.currentSessionID == sessionID else { return }
                self.detectedAgentType = result.agentType
                self.persistAgentDetection(
                    agentType: result.agentType,
                    cmdLineSessionID: result.isResume ? result.cbcSessionID : nil,
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
            detectedCBCSessionID = cmdLineSessionID
            onAgentDetected?(agentType, cmdLineSessionID)
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
            // Never clobber an existing valid binding. find-session guesses
            // which conversation this session owns from file timestamps, and
            // when several sessions share a project directory that guess is
            // wrong as often as it is right — it would silently rebind a
            // working session (e.g. one bound to a real conversation) to a
            // fresh empty one, and restoring on next launch would lose the
            // user's work. A binding that is already present and valid is
            // authoritative; only an explicit `--resume <other>` (an actual
            // user action) may change it.
            if let existing = SessionRestore.loadAll().first(where: { $0.sessionID == sessionID })?.cbcSessionID,
               !existing.isEmpty, existing != cbc,
               await service.agentSessionValid(agent: agentType, sessionID: existing),
               cmdLineSessionID == nil {
                detectedCBCSessionID = existing
                return
            }
            detectedCBCSessionID = cbc
            onAgentDetected?(agentType, cbc)
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
    nonisolated private func detectRunningAgent(shellPID: Int32) -> (agentType: AgentType, cbcSessionID: String?, isResume: Bool, processStartTime: Date?)? {
        // Check all descendants (not just direct children) in case agent runs in a subshell.
        guard let allPIDs = getDescendantPIDs(of: shellPID) else { return nil }

        var best: (AgentType, String?, Bool)? = nil
        var bestPriority = -1
        var bestStart: Date?
        for pid in allPIDs {
            let cmdLine = getCommandLine(of: pid) ?? ""
            for agent in AgentType.allCases {
                guard let match = agent.provider.detectProcess(cmdLine: cmdLine) else { continue }
                // Highest detection priority wins (e.g. a leftover codebuddy
                // process must not shadow the claude the user launched).
                if agent.detectionPriority > bestPriority {
                    // The command line only reflects the conversation at launch
                    // time. A user can /resume to a different conversation
                    // inside the agent, which changes the files the process
                    // opens but not argv — so resolve the live conversation
                    // from the process's open session files when possible.
                    let liveID = openSessionID(of: pid)
                    best = (agent, liveID ?? match.sessionID, match.isResume)
                    bestPriority = agent.detectionPriority
                    bestStart = getProcessStartTime(pid: pid)
                }
            }
        }
        guard let best else { return nil }
        return (agentType: best.0, cbcSessionID: best.1, isResume: best.2, processStartTime: bestStart)
    }

    /// Conversation a process is actually using right now, read from the
    /// `.codebuddy/projects/<dir>/<session-id>/...` files it has open (lsof).
    /// More trustworthy than argv: `codebuddy` followed by `/resume <id>`
    /// switches the conversation without changing the process command line.
    /// Returns nil when no session path is open.
    nonisolated private func openSessionID(of pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-p", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            // Lines look like:
            //   node 36049 ... /Users/limanshiang/.codebuddy/projects/Users-limanshiang/<session-id>/tool-results/...
            let marker = "/.codebuddy/projects/"
            guard let range = text.range(of: marker) else { return nil }
            let after = text[range.upperBound...]
            // Skip the encoded project dir (e.g. Users-limanshiang/), then take
            // the session-id directory component.
            guard let slash = after.firstIndex(of: "/") else { return nil }
            let remainder = after[after.index(after: slash)...]
            guard let end = remainder.firstIndex(of: "/") else { return nil }
            return String(remainder[..<end])
        } catch {
            return nil
        }
    }

    /// Start time of a process. `ps -o lstart` only has second precision,
    /// which is not enough to tell apart two agents launched in the same
    /// second (common when the user opens two sessions back to back). Use
    /// proc_pidinfo for microsecond precision so each freshly launched agent
    /// can be matched to the conversation file it actually created.
    nonisolated private func getProcessStartTime(pid: Int32) -> Date? {
        if let micro = Self.microsecondStartTime(pid: pid) {
            return micro
        }
        // Fall back to `ps -o lstart` (second precision) if proc_pidinfo is
        // unavailable.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "lstart="]
        // Force C locale: under a zh_CN system ps emits a localized date
        // ("六 8月/15 16:58:33 2026") that the English DateFormatter below
        // cannot parse, so every detection got a nil start time and no
        // session ever bound a conversation.
        task.environment = ["LC_ALL": "C", "LANG": "C"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return ProcessStartTimeParser.parse(text)
        } catch {
            return nil
        }
    }

    /// Process start time at microsecond precision via libproc.
    nonisolated private static func microsecondStartTime(pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, Int32(size))
        }
        guard r == size else { return nil }
        let sec = info.pbi_start_tvsec
        let usec = info.pbi_start_tvusec
        guard sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(sec) + Double(usec) / 1_000_000.0)
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
