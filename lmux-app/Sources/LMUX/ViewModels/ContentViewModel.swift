import SwiftUI
import LMUXCore
import Combine
import AppKit
import UserNotifications

@MainActor
class ContentViewModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var selectedSession: SessionSummary?
    @Published var searchText = ""
    /// Token bumped to request focus on the session search field (Cmd+F).
    @Published var searchFocusToken = UUID()
    @Published var connectedSessionId: String?
    @Published var selectedFullSession: Session?
    @Published var showNewSessionSheet = false
    @Published var backendRunning = false
    @Published var backendStarting = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var toastMessage: String?
    private var toastTask: Task<Void, Never>?

    let api = APIClient()

    init() {
        // Ensure agent/shell processes are terminated when the app quits, so
        // no orphaned codebuddy/claude processes are left behind.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.terminateAllProcesses()
        }
    }

    /// Terminate every running terminal/agent process and clear restore state.
    func terminateAllProcesses() {
        for mgr in terminalManagers.values {
            mgr.disconnect()
        }
        terminalManagers.removeAll()
        for mgr in splitTerminalManagers.values {
            mgr.disconnect()
        }
        splitTerminalManagers.removeAll()
        completedSessionIds.removeAll()
        activeSessionIds.removeAll()
        attentionSessionIds.removeAll()
    }

    /// Show a transient non-blocking toast (auto-dismisses after ~2.5s).
    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { toastMessage = nil }
        }
    }

    // MARK: - Export / import

    /// Present a save panel and export sessions + agent data to a tar.gz.
    func promptExportSessions() {
        let panel = NSSavePanel()
        panel.title = "Export lmux Sessions"
        panel.nameFieldStringValue = "lmux-backup-\(Self.dateStamp()).tar.gz"
        panel.allowedContentTypes = [.gzip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let ok = await exportSessions(to: url)
            showToast(ok ? "Exported to \(url.lastPathComponent)" : "Export failed")
        }
    }

    /// Present an open panel, import a tar.gz, and reload the backend.
    func promptImportSessions() {
        let panel = NSOpenPanel()
        panel.title = "Import lmux Sessions"
        panel.allowedContentTypes = [.gzip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let ok = await importSessions(from: url)
            showToast(ok ? "Import complete" : "Import failed")
        }
    }

    /// Pack lmux data (sessions.db, restore.json, codebuddy/claude settings +
    /// conversation projects) into a tar.gz for migration to another machine.
    func exportSessions(to url: URL) async -> Bool {
        let home = NSHomeDirectory()
        let args = [
            "-czf", url.path,
            "\(home)/.lmux",
            "\(home)/Library/Application Support/lmux/restore.json",
            "\(home)/.codebuddy/settings.json",
            "\(home)/.codebuddy/projects",
            "\(home)/.claude/settings.json",
            "\(home)/.claude/projects",
        ]
        let ok = await Self.runProcess("/usr/bin/tar", args)
        if !ok {
            errorMessage = "Export failed. Make sure the source data exists."
        }
        return ok
    }

    /// Restore lmux data from a tar.gz and restart the backend to reload it.
    /// If the backup was made under a different username, project paths and
    /// codebuddy/claude project directories are migrated to the current user.
    func importSessions(from url: URL) async -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("lmux-import-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let ok = await Self.runProcess("/usr/bin/tar", ["-xzf", url.path, "-C", tmp.path])
        guard ok else {
            try? fm.removeItem(at: tmp)
            errorMessage = "Import failed. The file may be corrupt or not an lmux backup."
            return false
        }

        // Stop the backend so the imported sessions.db can be replaced safely.
        if backendProcess?.isRunning == true {
            backendProcess?.terminate()
        }
        backendProcess = nil
        backendRunning = false

        // Locate the backup's user directory (Users/<name>/...).
        let usersDir = tmp.appendingPathComponent("Users")
        let backupName = (try? fm.contentsOfDirectory(atPath: usersDir.path))?.first(where: {
            $0 != ".DS_Store"
        })
        let currentName = NSUserName()

        if let backupName, let backupHome = usersDir.appendingPathComponent(backupName) as URL?, backupName != currentName {
            await Self.migrateImportedPaths(from: backupHome, fromUser: backupName, toUser: currentName)
        }

        // Move the imported data into the current user's home directory.
        let home = NSHomeDirectory()
        if let backupName, let backupHome = usersDir.appendingPathComponent(backupName) as URL? {
            Self.moveItemIfExists(from: backupHome.appendingPathComponent(".lmux"), to: "\(home)/.lmux")
            Self.moveItemIfExists(
                from: backupHome.appendingPathComponent("Library/Application Support/lmux/restore.json"),
                to: "\(home)/Library/Application Support/lmux/restore.json"
            )
            Self.moveItemIfExists(from: backupHome.appendingPathComponent(".codebuddy"), to: "\(home)/.codebuddy")
            Self.moveItemIfExists(from: backupHome.appendingPathComponent(".claude"), to: "\(home)/.claude")
        }

        try? fm.removeItem(at: tmp)

        await launchBackend()
        return true
    }

    /// Migrate a backup made under `fromUser` to the current user: rename
    /// codebuddy/claude project dirs, rewrite project paths in sessions.db and
    /// restore.json, and rewrite cwd references inside conversation JSONLs.
    private static func migrateImportedPaths(from backupHome: URL, fromUser: String, toUser: String) async {
        let fm = FileManager.default

        // 1. Rename codebuddy/claude project directories (encoded with the
        //    old username).
        let renames = [
            ".codebuddy/projects/Users-\(fromUser)": ".codebuddy/projects/Users-\(toUser)",
            ".claude/projects/-Users-\(fromUser)": ".claude/projects/-Users-\(toUser)",
        ]
        for (relSrc, relDst) in renames {
            let s = backupHome.appendingPathComponent(relSrc)
            if fm.fileExists(atPath: s.path) {
                try? fm.moveItem(at: s, to: backupHome.appendingPathComponent(relDst))
            }
        }

        // 2. Rewrite project paths in sessions.db.
        let dbPath = backupHome.appendingPathComponent(".lmux/sessions.db").path
        _ = await runProcess("/usr/bin/sqlite3", [
            dbPath,
            "UPDATE sessions SET project_dir = replace(project_dir, '/Users/\(fromUser)', '/Users/\(toUser)');",
        ])

        // 3. Rewrite restore.json.
        let restorePath = backupHome.appendingPathComponent("Library/Application Support/lmux/restore.json").path
        if let text = try? String(contentsOfFile: restorePath, encoding: .utf8) {
            let replaced = text.replacingOccurrences(of: "/Users/\(fromUser)", with: "/Users/\(toUser)")
            try? replaced.write(toFile: restorePath, atomically: true, encoding: .utf8)
        }

        // 4. Rewrite cwd references inside codebuddy/claude conversation JSONLs.
        for rel in [".codebuddy/projects", ".claude/projects"] {
            let dir = backupHome.appendingPathComponent(rel).path
            if fm.fileExists(atPath: dir) {
                let script = "find \"\(dir)\" -name '*.jsonl' -exec sed -i '' 's|/Users/\(fromUser)|/Users/\(toUser)|g' {} +"
                _ = await runProcess("/bin/bash", ["-lc", script])
            }
        }
    }

    private static func moveItemIfExists(from: URL, to: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        let dest = URL(fileURLWithPath: to)
        if fm.fileExists(atPath: to) {
            try? fm.removeItem(at: dest)
        }
        try? fm.moveItem(at: from, to: dest)
    }

    /// Run /usr/bin/tar with the given arguments, returning whether it succeeded.
    private static func runProcess(_ executable: String, _ args: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try p.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    /// Restart the backend so it re-reads the (possibly replaced) sessions.db.
    func restartBackend() async {
        if backendProcess?.isRunning == true {
            backendProcess?.terminate()
        }
        backendProcess = nil
        backendRunning = false
        await launchBackend()
    }
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
            if self?.selectedSession?.id == sessionID {
                self?.showToast("Connected")
            }
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

    /// The agent a session actually uses: live-detected first (e.g. claude
    /// started inside a bash session), then the detection recorded in
    /// restore.json, then the backend-configured agent type.
    func currentAgentType(for sessionID: String) -> AgentType {
        if let mgr = terminalManagers[sessionID], let detected = mgr.detectedAgentType {
            return detected
        }
        return configuredAgentType(for: sessionID)
    }

    /// The agent configured for a session (restore.json detection, then the
    /// backend agent type), without live-detection. Used as a fallback by
    /// views that observe the manager themselves.
    func configuredAgentType(for sessionID: String) -> AgentType {
        if let entry = SessionRestore.loadAll().first(where: { $0.sessionID == sessionID }),
           let at = entry.agentType {
            return at
        }
        return sessions.first(where: { $0.id == sessionID })?.agentType ?? .codebuddy
    }

    /// True when the session is (or was) an agent session per restore.json,
    /// as opposed to a plain bash session.
    func isAgentMode(for sessionID: String) -> Bool {
        SessionRestore.loadAll().first(where: { $0.sessionID == sessionID })?.launchMode == .agent
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
        showToast("Session stopped")
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

    // MARK: - Session navigation (keyboard shortcuts)

    /// Sessions filtered by the current search text.
    var visibleSessions: [SessionSummary] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    func selectNextSession() {
        let list = visibleSessions
        guard !list.isEmpty else { return }
        let currentID = selectedSession?.id
        let idx = list.firstIndex(where: { $0.id == currentID }) ?? -1
        selectSession(list[(idx + 1) % list.count])
    }

    func selectPreviousSession() {
        let list = visibleSessions
        guard !list.isEmpty else { return }
        let currentID = selectedSession?.id
        let idx = list.firstIndex(where: { $0.id == currentID }) ?? 0
        selectSession(list[(idx - 1 + list.count) % list.count])
    }

    /// Stop the currently selected session's process.
    func stopCurrentSession() {
        guard let id = selectedSession?.id else { return }
        killSession(id: id)
    }

    /// Request focus on the session search field.
    func focusSearch() {
        searchFocusToken = UUID()
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
            showToast("Session created")
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
            showToast("Session deleted")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSession(id: String, name: String) async {
        do {
            _ = try await api.renameSession(id: id, name: name)
            await refreshSessions()
            showToast("Session renamed")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Context usage (percentage + credit) for any agent's conversation,
    /// computed by that agent's provider.
    func agentContextUsage(agent: AgentType, cbcSessionID: String?, projectDir: String) async -> ContextUsageInfo? {
        guard backendRunning else { return nil }
        return await agent.provider.contextUsage(cbcSessionID: cbcSessionID, projectDir: projectDir, service: api)
    }

    /// Look up the most recent conversation for any agent in a project dir.
    func findAgentSession(agent: AgentType, projectDir: String) async -> String? {
        guard backendRunning else { return nil }
        guard let found = await api.findAgentSession(agent: agent, projectDir: projectDir),
              !found.isEmpty else { return nil }
        return found
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
        let agent = entry.agentType ?? .codebuddy
        let provider = agent.provider
        let isAgentMode = entry.launchMode == .agent

        // Candidate session ID: restore.json first, backend as fallback. The
        // provider decides whether it is valid for this agent and whether to
        // look up history.
        let effectiveCBC = (entry.cbcSessionID != nil && !entry.cbcSessionID!.isEmpty)
            ? entry.cbcSessionID
            : backend?.cbcSessionID

        let decision = await provider.resolveSession(
            cbcSessionID: effectiveCBC,
            projectDir: entry.projectDir,
            allowHistoryLookup: isAgentMode,
            service: api
        )

        let mgr = terminalManager(for: entry.sessionID)
        switch decision {
        case .resume(let sessionID):
            // Sync cbcSessionID back to the backend so all paths (restore +
            // connectToSession) see it.
            if let backend = backend, backend.cbcSessionID != sessionID {
                try? await api.setCBCSessionID(sessionID: entry.sessionID, cbcSessionID: sessionID)
            }
            mgr.connect(
                sessionID: entry.sessionID,
                projectDir: entry.projectDir,
                cbcSessionID: sessionID,
                agentType: agent
            )
        case .fresh:
            mgr.connect(
                sessionID: entry.sessionID,
                projectDir: entry.projectDir,
                cbcSessionID: nil,
                agentType: agent
            )
        case .bash:
            // New session without history: start a bash terminal. Agent
            // detection will upgrade to agent mode if the user launches an
            // agent manually inside the shell.
            mgr.connectBash(
                sessionID: entry.sessionID,
                projectDir: entry.projectDir,
                agentType: agent
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
