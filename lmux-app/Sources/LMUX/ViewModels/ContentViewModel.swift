import SwiftUI
import Combine
import AppKit
import UserNotifications

@MainActor
class ContentViewModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var selectedSession: SessionSummary?
    @Published var connectedSessionId: String?
    @Published var selectedFullSession: Session?
    @Published var showNewSessionSheet = false
    @Published var backendRunning = false
    @Published var backendStarting = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let api = APIClient()
    private var backendProcess: Process?
    private var pollTimer: Timer?
    /// DispatchIO reading the backend's stdout/stderr pipe. Kept as a property so
    /// retryBackend() can close it before terminating the process (prevents
    /// EV_VANISHED crashes from a closed pipe fd).
    private var backendIO: DispatchIO?
    /// Guards against double-close of backendIO.
    private var backendIOClosed = false

    /// Terminal pool: preserves TerminalManager instances across session switches.
    private var terminalManagers: [String: TerminalManager] = [:]
    /// Split pane terminal managers.
    private var splitTerminalManagers: [String: TerminalManager] = [:]

    /// Sessions with an actively running codebuddy-code process.
    @Published var activeSessionIds: Set<String> = []
    /// Sessions whose codebuddy-code process has exited (completed tasks).
    @Published var completedSessionIds: Set<String> = []
    /// Sessions that need user attention (completed while in background).
    @Published var attentionSessionIds: Set<String> = []

    // MARK: - Terminal Pool

    /// Get or create a TerminalManager for a session.
    func terminalManager(for sessionID: String) -> TerminalManager {
        if let existing = terminalManagers[sessionID] {
            return existing
        }
        let mgr = TerminalManager()
        mgr.onFirstOutput = { [weak self] in
            self?.activeSessionIds.insert(sessionID)
        }
        mgr.onProcessExit = { [weak self] in
            self?.activeSessionIds.remove(sessionID)
            self?.completedSessionIds.insert(sessionID)
            if self?.selectedSession?.id != sessionID {
                self?.attentionSessionIds.insert(sessionID)
                self?.sendCompletionNotification(sessionID: sessionID)
            }
        }
        mgr.onConnectError = { [weak self] message in
            self?.statusMessage = message
            self?.errorMessage = message
        }
        terminalManagers[sessionID] = mgr
        return mgr
    }

    /// Read-only access to an existing TerminalManager. Unlike
    /// `terminalManager(for:)` this never creates one, so list rows can
    /// query state without allocating managers for every session.
    func terminalManagerIfExists(for sessionID: String) -> TerminalManager? {
        terminalManagers[sessionID]
    }

    /// Release a terminal manager when its session is deleted.
    func releaseTerminalManager(for sessionID: String) {
        if let mgr = terminalManagers[sessionID] {
            mgr.disconnect()
            terminalManagers.removeValue(forKey: sessionID)
        }
        completedSessionIds.remove(sessionID)
        activeSessionIds.remove(sessionID)
        attentionSessionIds.remove(sessionID)
        splitTerminalManagers[sessionID]?.disconnect()
        splitTerminalManagers.removeValue(forKey: sessionID)
        SessionRestore.remove(sessionID: sessionID)
    }

    /// Get or create a split-pane TerminalManager for a session.
    func splitTerminalManager(for sessionID: String) -> TerminalManager {
        if let existing = splitTerminalManagers[sessionID] {
            return existing
        }
        let mgr = TerminalManager()
        splitTerminalManagers[sessionID] = mgr
        return mgr
    }

    /// Kill the running codebuddy process without deleting the session.
    func killSession(id: String) {
        if let mgr = terminalManagers[id] {
            mgr.disconnect()
        }
        splitTerminalManagers[id]?.disconnect()
        splitTerminalManagers.removeValue(forKey: id)
        completedSessionIds.remove(id)
        activeSessionIds.remove(id)
        attentionSessionIds.remove(id)
        if connectedSessionId == id {
            connectedSessionId = nil
        }
        if selectedSession?.id == id {
            selectedSession = nil
        }
    }

    /// Whether the codebuddy-code process is currently running for this session.
    func isSessionActive(_ sessionID: String) -> Bool {
        activeSessionIds.contains(sessionID)
    }

    /// Whether the codebuddy-code process has completed (exited) for this session.
    func hasSessionCompleted(_ sessionID: String) -> Bool {
        completedSessionIds.contains(sessionID)
    }

    /// Whether this session needs user attention (completed in background).
    func needsSessionAttention(_ sessionID: String) -> Bool {
        attentionSessionIds.contains(sessionID)
    }

    /// Clear the attention flag when user focuses the session.
    func clearSessionAttention(_ sessionID: String) {
        attentionSessionIds.remove(sessionID)
    }

    private func sendCompletionNotification(sessionID: String) {
        let name = sessions.first(where: { $0.id == sessionID })?.name ?? "Session"
        let content = UNMutableNotificationContent()
        content.title = "Task Complete"
        content.body = "\(name) has finished."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "lmux-complete-\(sessionID)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Backend Management

    /// The session selected when the app last quit. On restore we only
    /// auto-launch this one to avoid starting every agent at once.
    private var lastSelectedSessionID: String? {
        get { UserDefaults.standard.string(forKey: "lastSelectedSessionID") }
        set { UserDefaults.standard.set(newValue, forKey: "lastSelectedSessionID") }
    }

    func startBackend() {
        backendStarting = true
        Task {
            // try to connect to existing backend
            if await api.healthCheck() {
                let token = loadToken()
                let addr = loadAddr()
                if let token = token, let addr = addr {
                    api.configure(addr: addr, token: token)
                    backendRunning = true
                    backendStarting = false
                    await refreshSessions()
                    await restoreRunningSessions()
                    startPolling()
                    return
                }
            }

            // start backend process
            await launchBackend()
        }
    }

    func retryBackend() {
        // Close the pipe IO first so the DispatchIO doesn't hit a vanished
        // descriptor when we terminate the backend process.
        closeBackendIO()
        if backendProcess?.isRunning == true {
            backendProcess?.terminate()
        }
        backendProcess = nil
        backendStarting = true
        errorMessage = nil
        statusMessage = "Starting backend..."
        Task {
            await launchBackend()
        }
    }

    /// Close the backend's DispatchIO exactly once (safe to call from any path).
    private func closeBackendIO() {
        guard !backendIOClosed else { return }
        backendIOClosed = true
        backendIO?.close()
        backendIO = nil
    }

    private func launchBackend() async {
        // search for lmux binary in multiple locations
        let paths = findCBSPaths()

        var execPath: String?
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) {
                execPath = p
                break
            }
        }

        guard let execPath = execPath else {
            backendStarting = false
            errorMessage = "lmux backend not found. Try: cd ~/Projects/lmux && make build"
            statusMessage = "Backend not found"
            return
        }
        print("[lmux] Using backend at: \(execPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = []

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            backendProcess = process
            print("[lmux] Process started, PID: \(process.processIdentifier)")
        } catch {
            backendStarting = false
            errorMessage = "Failed to start backend: \(error.localizedDescription)"
            statusMessage = "Backend failed to start"
            return
        }

        // read token from output using a file handle readability handler
        var accumulatedOutput = ""
        let fileHandle = pipe.fileHandleForReading

        // Use DispatchIO for reliable async reading instead of polling
        let fd = fileHandle.fileDescriptor
        let dispatchIO = DispatchIO(type: .stream, fileDescriptor: fd, queue: .main) { _ in
            try? fileHandle.close()
        }
        backendIO = dispatchIO
        backendIOClosed = false

        dispatchIO.setLimit(lowWater: 1)
        dispatchIO.read(offset: 0, length: Int.max, queue: .main) { [weak self] done, data, error in
            guard let data = data, let chunk = String(data: Data(data), encoding: .utf8) else {
                if done { self?.closeBackendIO() }
                return
            }
            accumulatedOutput += chunk
            for line in accumulatedOutput.components(separatedBy: "\n") {
                if line.hasPrefix("LMUX_TOKEN=") {
                    self?.saveToken(String(line.dropFirst(11)))
                }
                if line.hasPrefix("LMUX_ADDR=") {
                    self?.saveAddr(String(line.dropFirst(10)))
                }
            }
            // Keep only the last partial line
            if let lastNewline = accumulatedOutput.lastIndex(of: "\n") {
                accumulatedOutput = String(accumulatedOutput[accumulatedOutput.index(after: lastNewline)...])
            }
            if self?.loadToken() != nil && self?.loadAddr() != nil {
                self?.closeBackendIO()
            }
            if done || error != nil { self?.closeBackendIO() }
        }

        // Wait for backend to be ready (single loop, 1s interval, 20s timeout).
        for _ in 0..<20 {
            if let token = loadToken(), let addr = loadAddr() {
                api.configure(addr: addr, token: token)
                if await api.healthCheck() {
                    closeBackendIO()
                    backendRunning = true
                    backendStarting = false
                    statusMessage = nil
                    await refreshSessions()
                    await restoreRunningSessions()
                    startPolling()
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        dispatchIO.close()

        closeBackendIO()
        backendStarting = false
        backendRunning = false
        errorMessage = "Backend failed to start on \(loadAddr() ?? "127.0.0.1:19680")"
        statusMessage = "Backend failed"
    }

    private func findCBSPaths() -> [String] {
        var paths: [String] = []

        // 1. Bundled in .app Contents/MacOS (production deployment)
        paths.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("lmux-backend")
            .path)

        // 2. Relative to executable (development: swift run / Xcode)
        if let execPath = Bundle.main.executableURL?.path {
            let execDir = URL(fileURLWithPath: execPath).deletingLastPathComponent()
            // Try backend/ subdirectory relative to executable
            paths.append(execDir
                .appendingPathComponent("backend")
                .appendingPathComponent("lmux")
                .path)
            // Try parent of parent (SPM .build/debug structure)
            paths.append(execDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("backend")
                .appendingPathComponent("lmux")
                .path)
        }

        // 3. Fallback: well-known paths
        let home = NSHomeDirectory()
        paths.append(home + "/Projects/lmux/bin/lmux")
        paths.append(home + "/.local/bin/lmux")

        // Filter to only existing executable files
        print("[lmux] Backend search paths: \(paths)")
        return paths.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Session Operations

    func refreshSessions() async {
        guard backendRunning else { return }

        do {
            let previousSelection = selectedSession?.id
            let summaries = try await api.listSessions()

            // Avoid triggering SwiftUI diff on every poll when nothing changed.
            // Compare full contents (status, pid, ai_title, ...) not just IDs,
            // so field-level updates from the backend reach the UI.
            guard summaries != sessions else { return }

            sessions = summaries

            // preserve selection across refresh
            if let prevId = previousSelection,
               let current = summaries.first(where: { $0.id == prevId }) {
                selectedSession = current
            }
            // clear any previous error on successful refresh
            if errorMessage != nil {
                errorMessage = nil
            }
        } catch {
            if backendRunning {
                // check if backend died
                if await !api.healthCheck() {
                    backendRunning = false
                    statusMessage = "Backend disconnected"
                    errorMessage = "Backend connection lost. Try restarting."
                } else {
                    statusMessage = "Refresh failed"
                    errorMessage = "Failed to refresh sessions: \(error.localizedDescription)"
                }
            }
        }
    }

    func selectSession(_ session: SessionSummary) {
        // Detach previous session
        if let prev = selectedSession, prev.id != session.id {
            terminalManagers[prev.id]?.detach()
            connectedSessionId = nil
        }
        selectedSession = session
        lastSelectedSessionID = session.id
        clearSessionAttention(session.id)
    }

    func createSession(projectDir: String, name: String?, cbcSessionID: String?, agentType: AgentType = .codebuddy) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let _ = try await api.createSession(
                projectDir: projectDir,
                name: name,
                cbcSessionID: cbcSessionID,
                agentType: agentType
            )
            await refreshSessions()
            // auto-select the new session so terminal connects immediately
            if let created = sessions.first(where: { $0.projectDir == projectDir && $0.name == (name ?? "") }) {
                selectedSession = created
            } else if let first = sessions.first {
                selectedSession = first
            }
            showNewSessionSheet = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func quickCreateSession(agentType: AgentType = .codebuddy) async {
        let home = NSHomeDirectory()
        await createSession(projectDir: home, name: nil, cbcSessionID: nil, agentType: agentType)
    }

    func deleteSession(id: String) async {
        do {
            try await api.deleteSession(id: id)
            releaseTerminalManager(for: id)
            if selectedSession?.id == id {
                selectedSession = nil
            }
            await refreshSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSession(id: String, name: String) async {
        do {
            _ = try await api.renameSession(id: id, name: name)
            await refreshSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Look up the most recent valid CodeBuddy conversation in a project
    /// directory, or nil when there is no history / backend unavailable.
    func findCodebuddySession(projectDir: String) async -> String? {
        guard backendRunning else { return nil }
        guard let found = try? await api.findCodebuddySession(projectDir: projectDir),
              !found.isEmpty else { return nil }
        return found
    }

    /// Returns true when `sessionID` refers to a real, resumable conversation.
    func isCodebuddySessionValid(_ sessionID: String?) async -> Bool {
        guard let sessionID, !sessionID.isEmpty, backendRunning else { return false }
        return await api.codebuddySessionValid(sessionID: sessionID)
    }

    /// Percentage (0-100) of the model's context window currently used by a
    /// codebuddy conversation, or nil when unavailable.
    func codebuddyContextPercent(cbcSessionID: String?) async -> Int? {
        guard let cbcSessionID, !cbcSessionID.isEmpty, backendRunning else { return nil }
        guard let info = await api.codebuddyContext(sessionID: cbcSessionID),
              info.contextWindow > 0, info.tokens > 0 else { return nil }
        return Int((Double(info.tokens) / Double(info.contextWindow) * 100).rounded())
    }

    /// Estimated credit spent on a codebuddy conversation, or nil when
    /// unavailable (no trace data or free model).
    func codebuddyContextCredit(cbcSessionID: String?) async -> Double? {
        guard let cbcSessionID, !cbcSessionID.isEmpty, backendRunning else { return nil }
        guard let info = await api.codebuddyContext(sessionID: cbcSessionID),
              info.credit > 0 else { return nil }
        return info.credit
    }

    func restoreAll() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let count = try await api.restoreAll()
            statusMessage = "Restored \(count) sessions"
            await refreshSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attachToSession(_ session: SessionSummary) async {
        selectSession(session)
    }

    // Get session project directory for terminal spawning
    func getSessionProjectDir(id: String) -> String? {
        // sessions are already loaded, find the project dir from summaries
        return sessions.first(where: { $0.id == id })?.projectDir
    }

    // MARK: - Session Restore

    /// Re-launch sessions that were running before the app was last quit.
    private func restoreRunningSessions() async {
        let entries = SessionRestore.loadAll()
        guard !entries.isEmpty else { return }

        // Batch-create any sessions missing from the backend.
        var needsRefresh = false
        for entry in entries {
            if sessions.first(where: { $0.id == entry.sessionID }) == nil {
                _ = try? await api.createSession(
                    projectDir: entry.projectDir,
                    name: nil,
                    cbcSessionID: entry.cbcSessionID,
                    agentType: entry.agentType ?? .codebuddy
                )
                needsRefresh = true
            }
        }
        if needsRefresh { await refreshSessions() }

        // Restore only the session that was selected when the app quit; the
        // rest connect lazily when the user opens them. Auto-restoring every
        // agent session spawns many codebuddy processes that each load their
        // full conversation history, which makes launch slow.
        let autoRestoreID = lastSelectedSessionID ?? entries.first?.sessionID
        guard let targetID = autoRestoreID,
              let entry = entries.first(where: { $0.sessionID == targetID }) else {
            return
        }

        // Re-fetch the backend session so we can fall back to its cbcSessionID
        let backend = sessions.first(where: { $0.id == entry.sessionID })

        // Prefer restore.json cbcSessionID, but fall back to backend if missing.
        let restoreCBC = entry.cbcSessionID
        let backendCBC = backend?.cbcSessionID
        var effectiveCBC = (restoreCBC != nil && !restoreCBC!.isEmpty) ? restoreCBC : backendCBC

        let mgr = terminalManager(for: entry.sessionID)
        let isAgentMode = entry.launchMode == .agent

        // Only look up a codebuddy session ID from JSONL when this is
        // known to be an agent session. Also re-resolve when the persisted
        // ID is stale/invalid (e.g. a stub session saved before it had any
        // assistant reply).
        if isAgentMode {
            let cbcValid = await isCodebuddySessionValid(effectiveCBC)
            if !cbcValid {
                if let found = await findCodebuddySession(projectDir: entry.projectDir) {
                    effectiveCBC = found
                }
            }
        }

        let hasEffectiveCBC = (effectiveCBC != nil && !effectiveCBC!.isEmpty)

        // Sync cbcSessionID back to the backend so all paths (restore + connectToSession) see it.
        // Also correct stale values that were re-resolved above.
        if hasEffectiveCBC, let backend = backend, backend.cbcSessionID != effectiveCBC {
            try? await api.setCBCSessionID(sessionID: entry.sessionID, cbcSessionID: effectiveCBC!)
        }

        if isAgentMode || hasEffectiveCBC {
            mgr.connect(
                sessionID: entry.sessionID,
                projectDir: entry.projectDir,
                cbcSessionID: effectiveCBC,
                agentType: entry.agentType ?? .codebuddy
            )
        } else {
            // New session without history: start a bash terminal. Agent
            // detection will upgrade to agent mode if the user launches
            // codebuddy/claude manually inside the shell.
            mgr.connectBash(
                sessionID: entry.sessionID,
                projectDir: entry.projectDir,
                agentType: entry.agentType ?? .codebuddy
            )
        }

        // Select the restored session so its terminal shows.
        if let summary = sessions.first(where: { $0.id == targetID }) {
            selectedSession = summary
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSessions()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Persistence

    private func saveToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "lmux_token")
    }

    private func loadToken() -> String? {
        UserDefaults.standard.string(forKey: "lmux_token")
    }

    private func saveAddr(_ addr: String) {
        UserDefaults.standard.set(addr, forKey: "lmux_addr")
    }

    private func loadAddr() -> String? {
        UserDefaults.standard.string(forKey: "lmux_addr")
    }
}
