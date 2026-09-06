import SwiftUI
import LMUXCore
import Combine
import AppKit
import Darwin
import UserNotifications

@MainActor
class ContentViewModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var selectedSession: SessionSummary?
    @Published var searchText = ""
    /// Token bumped to request focus on the session search field (Cmd+F).
    @Published var searchFocusToken = UUID()
    /// Session currently being edited in the Edit Session sheet.
    @Published var editingSession: SessionSummary?
    @Published var connectedSessionId: String?
    @Published var selectedFullSession: Session?
    @Published var showNewSessionSheet = false
    @Published var showHelp = false
    @Published var showUsageStats = false
    @Published var usageStats: [SessionUsageStat] = []
    @Published var usageStatsLoading = false
    @Published var backendRunning = false
    @Published var backendStarting = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var toastMessage: String?
    @Published var syncInProgress = false

    // MARK: - Agent browser state

    /// Filesystem-level agent conversations for the current Agent filter.
    @Published var agentConversations: [AgentConversation] = []
    @Published var agentConversationsLoading = false
    /// Count of conversations hidden because they are already bound to an
    /// lmux session (resuming them here would duplicate the session).
    @Published var agentHiddenBound = 0
    /// Browser favourites: starred conversation ids (persisted locally).
    @Published var agentStars: Set<String> = []
    /// Selected filter: agent name ("", "codebuddy", "claude").
    @Published var agentFilterName = ""
    /// Selected filter: a single project directory, or "" for all.
    @Published var agentFilterProjectDir = ""
    @Published var agentConversationsError: String?
    /// Monotonic guard against out-of-order agent list reloads.
    private var agentLoadRequestID = 0
    /// Conversation shown in the Agent browser's preview pane.
    @Published var agentPreviewConversation: AgentConversation?
    @Published var agentPreview: AgentConversationPreview?
    @Published var agentPreviewLoading = false
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
        agentStars = loadAgentStars()
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

    /// Present a save panel and export the current session's conversation as
    /// a self-contained `.lmuxsession` file.
    func promptExportSession(_ session: SessionSummary) {
        let panel = NSSavePanel()
        panel.title = "Export Session"
        panel.nameFieldStringValue = "\(session.name).lmuxsession"
        panel.allowedContentTypes = [.lmuxSession]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let bundle = try await api.exportSession(sessionID: session.id)
                try bundle.toJSON().write(to: url, options: [.atomic])
                showToast("Exported \(url.lastPathComponent)")
            } catch {
                showToast("Export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Present an open panel for a `.lmuxsession` file and import the session.
    /// The target project directory is taken from the bundle itself (the last
    /// working directory the agent recorded) instead of asking the user to
    /// pick one. When that directory does not exist locally (e.g. the session
    /// came from another machine with a different path), tell the user and let
    /// them pick the actual directory.
    func promptImportSession() {
        let filePanel = NSOpenPanel()
        filePanel.title = "Import Session"
        filePanel.allowedContentTypes = [.lmuxSession]
        filePanel.canChooseFiles = true
        filePanel.canChooseDirectories = false
        guard filePanel.runModal() == .OK, let fileURL = filePanel.url else { return }
        guard let bundle = SessionExportBundle.fromJSON(fileURL) else {
            showToast("Import failed: invalid .lmuxsession file")
            return
        }

        // Auto target: the bundle's recorded working directory, path-mapped,
        // falling back to its configured project dir.
        let recorded = bundle.cwd ?? bundle.projectDir
        let targetDir = SessionSync.applyPathMappings(recorded)

        if !FileManager.default.fileExists(atPath: targetDir, isDirectory: nil) {
            let alert = NSAlert()
            alert.messageText = "Working Directory Not Found"
            alert.informativeText = "This session's working directory doesn't exist on this Mac:\n\n\(targetDir)\n\nPick the folder this session should live in, or cancel."
            alert.addButton(withTitle: "Choose Folder…")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let dirPanel = NSOpenPanel()
            dirPanel.title = "Choose Session Working Directory"
            dirPanel.canChooseFiles = false
            dirPanel.canChooseDirectories = true
            dirPanel.prompt = "Import Here"
            guard dirPanel.runModal() == .OK, let dirURL = dirPanel.url else { return }
            Task {
                await importSession(bundle, into: dirURL.path)
            }
            return
        }

        Task {
            await importSession(bundle, into: targetDir)
        }
    }

    /// Imports a bundle into the given project directory, asking the user how
    /// to resolve a conflict when the conversation already exists.
    private func importSession(_ bundle: SessionExportBundle, into projectDir: String) async {
        do {
            _ = try await api.importSession(bundle, projectDir: projectDir, conflictMode: nil)
            showToast("Imported \(bundle.name)")
        } catch APIError.conflict {
            let alert = NSAlert()
            alert.messageText = "Session Already Exists"
            alert.informativeText = "A session for this conversation already exists on this machine. Overwrite it, or import a new independent copy?"
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "New Copy")
            alert.addButton(withTitle: "Cancel")
            let choice = alert.runModal()
            switch choice {
            case .alertFirstButtonReturn:
                await doImport(bundle, into: projectDir, mode: "overwrite")
            case .alertSecondButtonReturn:
                await doImport(bundle, into: projectDir, mode: "new")
            default:
                break
            }
        } catch {
            showToast("Import failed: \(error.localizedDescription)")
        }
        await refreshSessions()
    }

    private func doImport(_ bundle: SessionExportBundle, into projectDir: String, mode: String) async {
        do {
            let session = try await api.importSession(bundle, projectDir: projectDir, conflictMode: mode)
            showToast("Imported \(session.name)")
        } catch {
            showToast("Import failed: \(error.localizedDescription)")
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
    ///
    /// Everything is MERGED into the current machine rather than replaced:
    /// replacing ~/.codebuddy or ~/.claude wholesale destroyed live data and
    /// failed silently when files were in use (e.g. CodeBuddy running), which
    /// left the session list imported but the conversation JSONLs missing.
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

        // Stop the backend so the imported sessions.db can be merged safely.
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

        // Merge the imported data into the current user's home directory.
        let home = NSHomeDirectory()
        if let backupName, let backupHome = usersDir.appendingPathComponent(backupName) as URL? {
            // Merge the session database row-by-row so sessions already on
            // this machine are preserved. The backup's config.json is NOT
            // imported (its data_dir points at the old user's home).
            let backupLMUX = backupHome.appendingPathComponent(".lmux")
            if fm.fileExists(atPath: backupLMUX.appendingPathComponent("sessions.db").path) {
                await Self.mergeSQLite(
                    from: backupLMUX.appendingPathComponent("sessions.db").path,
                    into: "\(home)/.lmux/sessions.db"
                )
            }
            Self.mergeRestoreJSON(
                from: backupHome.appendingPathComponent("Library/Application Support/lmux/restore.json").path,
                to: "\(home)/Library/Application Support/lmux/restore.json"
            )
            Self.mergeCopy(
                from: backupHome.appendingPathComponent(".codebuddy"),
                to: URL(fileURLWithPath: "\(home)/.codebuddy")
            )
            Self.mergeCopy(
                from: backupHome.appendingPathComponent(".claude"),
                to: URL(fileURLWithPath: "\(home)/.claude")
            )
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
        //    old username). Match any dir whose name starts with the encoded
        //    old user dir, so both "Users-limanshiang" and
        //    "Users-limanshiang-lmux-test-agent" are handled.
        let roots = [
            ".codebuddy/projects",
            ".claude/projects",
        ]
        for relRoot in roots {
            let root = backupHome.appendingPathComponent(relRoot)
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.contains(fromUser) {
                let from = root.appendingPathComponent(name)
                let to = root.appendingPathComponent(name.replacingOccurrences(of: fromUser, with: toUser))
                if fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
                    try? fm.moveItem(at: from, to: to)
                }
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

    /// Recursively merge `from` into `to`. Files that already exist in `to`
    /// are replaced by the backup; other files/directories are added. The
    /// destination is never deleted, so live data on this machine survives.
    private static func mergeCopy(from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        try? fm.createDirectory(at: to, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let dest = to.appendingPathComponent(item.lastPathComponent)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    mergeCopy(from: item, to: dest)
                } else {
                    try? fm.removeItem(at: dest)
                    try? fm.copyItem(at: item, to: dest)
                }
            }
        }
    }

    /// Merge every row of `fromDB` into `toDB`, backup winning on conflicts.
    private static func mergeSQLite(from fromDB: String, into toDB: String) async {
        let fm = FileManager.default
        let destDir = URL(fileURLWithPath: toDB).deletingLastPathComponent()
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: fromDB) else { return }
        _ = await runProcess("/usr/bin/sqlite3", [
            toDB,
            "ATTACH '\(fromDB)' AS src; INSERT OR REPLACE INTO sessions SELECT * FROM src.sessions; DETACH src;",
        ])
    }

    /// Merge the backup's restore.json into the current one by session ID,
    /// keeping entries that already exist on this machine.
    private static func mergeRestoreJSON(from: String, to: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from) else { return }
        let dest = URL(fileURLWithPath: to)
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        var merged: [[String: Any]] = []
        if let data = try? Data(contentsOf: dest),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            merged = existing
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: from)),
           let incoming = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for entry in incoming {
                if let sid = entry["sessionID"] as? String {
                    merged.removeAll { ($0["sessionID"] as? String) == sid }
                }
                merged.append(entry)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]) {
            try? data.write(to: dest)
        }
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
    /// Incremented whenever a TerminalManager is created. List rows read this
    /// so a row that first rendered without a manager (SessionRowStatic) is
    /// re-evaluated once the manager exists — otherwise the context-usage
    /// row only appears after an unrelated viewModel change (e.g. switching
    /// sessions triggers refreshSessions).
    @Published private(set) var managerGeneration = 0
    /// Agent type detected per session, published globally so list rows that
    /// are not observing the manager still show the context-usage line.
    @Published private(set) var detectedAgents: [String: AgentType] = [:]
    /// Conversation ID detected per session (see detectedAgents).
    @Published private(set) var detectedCBCs: [String: String] = [:]

    // MARK: - Terminal Pool

    /// Get or create a TerminalManager for a session.
    func terminalManager(for sessionID: String) -> TerminalManager {
        if let existing = terminalManagers[sessionID] {
            return existing
        }
        let mgr = TerminalManager()
        managerGeneration += 1
        mgr.agentSessionService = api
        mgr.onAgentDetected = { [weak self] agent, cbc in
            guard let self else { return }
            self.detectedAgents[sessionID] = agent
            if let cbc, !cbc.isEmpty {
                // One conversation maps to one lmux session. find-session is a
                // project-wide "most recently active" lookup, so when two
                // sessions both run codebuddy it can return the SAME cbc for
                // both — which would make both sessions resume each other's
                // conversation on restart. If another session already claimed
                // this cbc, keep this session's existing binding instead of
                // clobbering it.
                let claimedByOther = self.detectedCBCs.contains { $0.key != sessionID && $0.value == cbc }
                if claimedByOther, let existing = self.detectedCBCs[sessionID], existing != cbc {
                    return
                }
                let alreadySynced = self.detectedCBCs[sessionID] == cbc
                self.detectedCBCs[sessionID] = cbc
                // Persist to the backend so a relaunch (or a list refresh
                // after app restart) still has cbc_session_id set — otherwise
                // the context-usage row disappears until the session is
                // re-detected or switched away. Backend overwrite is idempotent.
                // refreshSessions is safe now: the backend orders by created_at,
                // so the sidebar never re-sorts on detection.
                guard !alreadySynced else { return }
                Task {
                    try? await self.api.setCBCSessionID(sessionID: sessionID, cbcSessionID: cbc)
                    await self.refreshSessions()
                }
            }
        }
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

    /// True when the session is actually bound to an agent conversation —
    /// either via a known conversation id, a live-detected one, or an agent
    /// launch mode. Used to keep unstarted sessions out of the agent groups.
    func isBoundToAgent(_ session: SessionSummary) -> Bool {
        if let cbc = session.cbcSessionID, !cbc.isEmpty {
            return true
        }
        if let cbc = detectedCBCs[session.id], !cbc.isEmpty {
            return true
        }
        if isAgentMode(for: session.id) {
            return true
        }
        // A claude/codebuddy agent detected live inside a bash session.
        if let mgr = terminalManagers[session.id], mgr.detectedAgentType != nil {
            return true
        }
        return false
    }

    /// Pre-computed grouping of the given sessions into one bucket per agent
    /// type plus an "unbound" bucket. Computed with a single restore.json read
    /// (and a single pass over the sessions), so a large list never triggers
    /// N×M `loadAll()`/dictionary lookups from the view body.
    struct SessionGrouping {
        var bound: [AgentType: [SessionSummary]] = [:]
        var unbound: [SessionSummary] = []
        var agentOrder: [AgentType] = [.codebuddy, .claude]
    }

    func groupSessions(_ list: [SessionSummary]) -> SessionGrouping {
        let restore = SessionRestore.loadAll()
        var grouping = SessionGrouping()

        for session in list {
            var bound = false
            if let cbc = session.cbcSessionID, !cbc.isEmpty {
                bound = true
            } else if let cbc = detectedCBCs[session.id], !cbc.isEmpty {
                bound = true
            } else if restore.contains(where: { $0.sessionID == session.id && $0.launchMode == .agent }) {
                bound = true
            } else if terminalManagers[session.id]?.detectedAgentType != nil {
                bound = true
            }

            if bound {
                let agent = currentAgentType(for: session.id)
                grouping.bound[agent, default: []].append(session)
            } else {
                grouping.unbound.append(session)
            }
        }

        // Keep a stable group order for the sidebar.
        grouping.agentOrder = [.codebuddy, .claude].filter { grouping.bound[$0]?.isEmpty == false }
        return grouping
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

    /// Session IDs and the highest context threshold already notified for
    /// each. Prevents repeated notifications while the context stays above
    /// a threshold; the entry is reset when usage drops below it again.
    private var notifiedContextThresholds: [String: Int] = [:]

    /// Fire a desktop notification when a session's context usage crosses a
    /// high-water mark (e.g. 80% / 90%), reminding the user to run /compact.
    /// Each (session, threshold) pair notifies at most once per crossing —
    /// usage must drop below the threshold before it can fire again.
    func notifyIfContextHigh(sessionID: String, percent: Int) {
        // Use thresholds >= 80 and >= 90; ignore lower values.
        let thresholds = [80, 90]
        guard let hit = thresholds.last(where: { percent >= $0 }) else {
            // Below any threshold: clear the notch so a future rise re-fires.
            notifiedContextThresholds[sessionID] = nil
            return
        }
        let notified = notifiedContextThresholds[sessionID] ?? 0
        guard hit > notified else { return }
        notifiedContextThresholds[sessionID] = hit

        let name = sessions.first(where: { $0.id == sessionID })?.name ?? "Session"
        let content = UNMutableNotificationContent()
        content.title = "Context \(percent)%"
        content.body = "\(name) 上下文已用 \(percent)%。建议执行 /compact 压缩。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "lmux-context-\(sessionID)-\(hit)-\(UUID().uuidString)",
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
            // Kill any existing lmux backend process so the freshly bundled
            // binary is always the one serving this launch. Otherwise a
            // backend left over from a previous app version keeps running on
            // the port and the new app silently talks to the old code.
            await killExistingBackend()

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

    /// Terminate any process listening on the backend port. Returns when the
    /// port is free (or a short timeout elapses), so launchBackend() can bind
    /// it immediately.
    private func killExistingBackend() async {
        let port = backendPort()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -sTCP:LISTEN restricts to the process actually bound to the port,
        // so the app itself (which merely connects as a client) is never
        // matched.
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            print("[lmux] lsof failed: \(error.localizedDescription)")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let pids = text.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        for pid in pids where pid > 0 {
            // Only kill our own backend binary, never an unrelated process
            // that happens to use the port.
            if isLmuxBackend(pid) {
                print("[lmux] Killing existing backend PID \(pid)")
                kill(pid, SIGKILL)
            }
        }
        // Give the port a moment to be released before the new backend binds.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Whether the given PID is the lmux backend binary. Uses the full command
    /// line (`ps -o command=`) because `comm` is truncated to 16 chars
    /// ("lmux-backend" → "lmux-back").
    private func isLmuxBackend(_ pid: Int32) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let command = String(data: data, encoding: .utf8) ?? ""
        // Match either the bundled binary name or an in-development binary
        // whose full path ends in /lmux.
        return command.contains("lmux-backend")
            || command.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/lmux")
    }

    /// Backend port from the persisted addr (e.g. "127.0.0.1:19680"), or the
    /// default 19680 when not yet known.
    private func backendPort() -> Int {
        if let addr = loadAddr(),
           let port = addr.split(separator: ":").last,
           let value = Int(port) {
            return value
        }
        return 19680
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
        // A session already running in its own pop-out window has its terminal
        // attached there; showing it in the main window again would double-attach.
        if session.id != selectedSession?.id, SessionWindowController.shared.isOpen(sessionID: session.id) {
            showToast("Session '\(session.name)' is open in its own window")
            return
        }
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
            let created = try await api.createSession(
                projectDir: projectDir,
                name: name,
                cbcSessionID: cbcSessionID,
                agentType: agentType
            )
            await refreshSessions()
            showToast("Session created")
            // Auto-select the new session so the terminal connects immediately.
            // Use the created session's id (never a name/project match, which
            // can hit an older pinned session with the same project).
            if let session = sessions.first(where: { $0.id == created.id }) {
                selectSession(session)
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

    /// Toggle the pinned (starred) flag that keeps a session at the top.
    func togglePin(session: SessionSummary) async {
        do {
            _ = try await api.setPinned(id: session.id, pinned: !session.pinned)
            await refreshSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Open the edit sheet for a stopped session.
    func promptEditSession(_ session: SessionSummary) {
        editingSession = session
    }

    /// Apply optional edits (name, project dir, conversation ID) to a session.
    func editSession(id: String, name: String?, projectDir: String?, cbcSessionID: String?) async {
        do {
            _ = try await api.updateSession(id: id, name: name, projectDir: projectDir, cbcSessionID: cbcSessionID)
            // A project_dir change must not be overwritten by restore.json's
            // stale path on next launch, so drop the cached restore entry.
            SessionRestore.remove(sessionID: id)
            await refreshSessions()
            showToast("Session updated")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Latest working directory this session's agent recorded, if any. Used to
    /// prefill the project directory in the edit sheet.
    func agentWorkingDir(for session: SessionSummary) async -> String? {
        guard let cbc = session.cbcSessionID, !cbc.isEmpty else { return nil }
        return await api.agentCwd(agent: session.agentType, projectDir: session.projectDir, sessionID: cbc)
    }

    // MARK: - Agent browser favourites

    private static let agentStarsKey = "agent_browser_stars"

    private func loadAgentStars() -> Set<String> {
        let saved = UserDefaults.standard.stringArray(forKey: Self.agentStarsKey) ?? []
        return Set(saved)
    }

    func toggleAgentStar(_ conversationID: String) {
        if agentStars.contains(conversationID) {
            agentStars.remove(conversationID)
        } else {
            agentStars.insert(conversationID)
        }
        UserDefaults.standard.set(Array(agentStars), forKey: Self.agentStarsKey)
    }

    /// Reload the Agent browser list for the current filter. Keeps the existing
    /// list when a refresh fails so the UI doesn't flash empty. Guarded by a
    /// monotonically increasing request id so fast filter changes never let an
    /// older (slower) request overwrite a newer one.
    func loadAgentConversations() async {
        guard backendRunning else { return }
        agentLoadRequestID += 1
        let requestID = agentLoadRequestID
        agentConversationsLoading = true
        agentConversationsError = nil
        defer { agentConversationsLoading = false }

        let agent = agentFilterName.isEmpty ? nil : agentFilterName
        let dir = agentFilterProjectDir.isEmpty ? nil : agentFilterProjectDir
        do {
            let result = try await api.agentConversations(agent: agent, projectDir: dir)
            guard requestID == agentLoadRequestID else { return }
            agentConversations = result.conversations
            agentHiddenBound = result.hidden
        } catch {
            guard requestID == agentLoadRequestID else { return }
            agentConversationsError = error.localizedDescription
        }
    }

    /// Load the preview (title/summary metadata already in the list row plus
    /// the recent readable messages) for a selected agent conversation.
    func loadAgentPreview(_ conv: AgentConversation) async {
        agentPreviewLoading = true
        agentPreview = nil
        agentPreviewConversation = conv
        defer { agentPreviewLoading = false }
        do {
            agentPreview = try await api.agentConversationPreview(agent: conv.agent, sessionID: conv.id)
        } catch {
            agentPreview = AgentConversationPreview(rows: [])
        }
    }

    /// Resume a raw agent conversation as a new lmux session (and connect).
    /// If the JSONL is missing locally, first try to pull it back from the
    /// sync mirror so the agent can actually resume it.
    func resumeAgentConversation(_ conv: AgentConversation) async {
        guard let agentType = AgentType(rawValue: conv.agent) else {
            showToast("Unknown agent \(conv.agent)")
            return
        }
        let projectDir = conv.cwd ?? NSHomeDirectory()
        SessionSync.restoreAgentFileIfMissing(
            agentName: conv.agent,
            sessionID: conv.id,
            fileRel: conv.fileRel,
            projectDir: projectDir
        )
        await createSession(projectDir: projectDir, name: nil, cbcSessionID: conv.id, agentType: agentType)
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
        guard let found = await api.findAgentSession(agent: agent, projectDir: projectDir, after: nil),
              !found.isEmpty else { return nil }
        return found
    }

    /// Load per-session usage statistics (tokens / credit / model) for the
    /// statistics panel.
    func loadUsageStats() async {
        guard backendRunning else { return }
        usageStatsLoading = true
        defer { usageStatsLoading = false }
        do {
            usageStats = try await api.sessionUsageStats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Cross-device sync

    /// Manual sync pass: export changed pinned sessions to the sync directory
    /// and import newer remote files. No longer called automatically by the
    /// polling timer — sync is explicit ("Sync Now", or prompted on quit).
    func syncIfEnabled() async {
        guard SessionSync.isEnabled, SessionSync.syncDir != nil else { return }

        // Export: pinned sessions whose conversation changed. Incremental —
        // the backend returns only the appended JSONL, merged into the local
        // sync copy.
        for session in sessions where session.pinned && !(session.cbcSessionID ?? "").isEmpty {
            guard let cbcID = session.cbcSessionID, !cbcID.isEmpty else { continue }
            do {
                let since = SessionSync.exportedOffset(for: cbcID)
                let bundle = try await api.exportSession(sessionID: session.id, since: since)
                let result = SessionSync.applyIncrementalExport(bundle)
                if result == .needsFullExport {
                    // Local copy missing or out of sync: drop the tracked
                    // offset and resend the full conversation.
                    SessionSync.resetExportedOffset(for: cbcID)
                    let full = try await api.exportSession(sessionID: session.id)
                    _ = SessionSync.applyIncrementalExport(full)
                }
            } catch {
                // Session may not have a conversation yet; ignore.
                continue
            }
        }

        // Import: newer remote files from the sync directory. "overwrite"
        // updates the existing session with the same cbc id (or creates one
        // on first import), so repeated syncs never spawn duplicates.
        var importedAny = false
        let imported = await SessionSync.importIfChanged(
            importBundle: { bundle, mode in
                // Apply path mappings so the remote machine's paths resolve here.
                var mapped = bundle
                mapped.projectDir = SessionSync.applyPathMappings(bundle.projectDir)
                mapped.content = SessionSync.applyPathMappings(bundle.content)

                do {
                    let _ = try await api.importSession(mapped, projectDir: mapped.projectDir, conflictMode: mode)
                    importedAny = true
                } catch {
                    throw error
                }
            },
            onConflict: { info in
                await Self.promptSyncConflict(info)
            }
        )
        if importedAny {
            await refreshSessions()
            showToast("Imported \(imported.count) synced session(s)")
        }
    }

    /// Whether sync is enabled AND at least one pinned session exists — the
    /// condition used to offer a sync prompt on quit.
    var hasPinnedSessionsForSync: Bool {
        guard SessionSync.isEnabled, SessionSync.syncDir != nil else { return false }
        return sessions.contains { $0.pinned }
    }

    /// Manual "Sync Now": exports changed pinned sessions to the sync
    /// directory and imports newer remote files. Returns per-pass counts so
    /// the caller can tell the user whether anything actually happened.
    ///
    /// Result of a manual sync pass, for the confirmation toast / status.
    struct SyncNowResult {
        var exportedSessions = 0
        var importedSessions = 0
        /// Agent JSONL mirror counts (SessionSync.runAgentMirror), when the
        /// Agent Conversations mirror toggle is on.
        var agentExported = 0
        var agentImported = 0
        var agentConflicts = 0
        /// Two-way mirror conflicts, presented to the user for resolution.
        var agentConflictFiles: [SessionSync.AgentMirrorConflict] = []

        /// True when nothing was exported or imported this pass (nothing to
        /// do). Note: a session whose export silently failed (no conversation
        /// yet) also lands here.
        var isUpToDate: Bool {
            exportedSessions == 0 && importedSessions == 0
                && agentExported == 0 && agentImported == 0
        }
    }

    /// Live phase of Sync Now, shown in the wait overlay.
    enum SyncPhase: Equatable {
        case idle
        /// Exporting pinned session `current` of `total`.
        case exporting(current: Int, total: Int)
        /// Importing remote .lmuxsession bundles.
        case importing
        /// Agent JSONL mirror pass (`detail` e.g. "export CodeBuddy").
        case mirroring(detail: String)
    }

    @Published private(set) var syncPhase: SyncPhase = .idle
    /// Two-way agent-mirror conflicts surfaced after a Sync Now pass.
    @Published var mirrorConflicts: [SessionSync.AgentMirrorConflict] = []
    @Published var showMirrorConflicts = false

    func dismissMirrorConflict(id: String) {
        mirrorConflicts.removeAll { $0.id == id }
    }

    /// Replace the local JSONL with the mirror copy for a two-way conflict.
    func resolveMirrorConflictUseRemote(_ conflict: SessionSync.AgentMirrorConflict) {
        if SessionSync.resolveMirrorConflict(agentName: conflict.agentName, fileRel: conflict.fileRel) {
            dismissMirrorConflict(id: conflict.id)
            showToast("Replaced local copy with mirror version")
        } else {
            showToast("Could not resolve conflict — file missing")
        }
    }

    @discardableResult
    func syncNow() async -> SyncNowResult {
        guard SessionSync.isEnabled, SessionSync.syncDir != nil else {
            showToast("Sync not configured — enable it in Settings")
            return SyncNowResult()
        }
        syncInProgress = true
        defer {
            syncInProgress = false
            syncPhase = .idle
        }

        var result = SyncNowResult()
        // Export pass (same logic as syncIfEnabled).
        let pinned = sessions.filter { $0.pinned && !($0.cbcSessionID ?? "").isEmpty }
        for (idx, session) in pinned.enumerated() {
            guard let cbcID = session.cbcSessionID, !cbcID.isEmpty else { continue }
            syncPhase = .exporting(current: idx + 1, total: pinned.count)
            do {
                let since = SessionSync.exportedOffset(for: cbcID)
                let bundle = try await api.exportSession(sessionID: session.id, since: since)
                let export = SessionSync.applyIncrementalExport(bundle)
                if export == .needsFullExport {
                    SessionSync.resetExportedOffset(for: cbcID)
                    let full = try await api.exportSession(sessionID: session.id)
                    _ = SessionSync.applyIncrementalExport(full)
                    result.exportedSessions += 1
                } else if export == .updated {
                    result.exportedSessions += 1
                }
            } catch {
                // Session may not have a conversation yet; ignore.
                continue
            }
        }

        // Import pass.
        var importedAny = false
        syncPhase = .importing
        let imported = await SessionSync.importIfChanged(
            importBundle: { bundle, mode in
                var mapped = bundle
                mapped.projectDir = SessionSync.applyPathMappings(bundle.projectDir)
                mapped.content = SessionSync.applyPathMappings(bundle.content)
                do {
                    let _ = try await api.importSession(mapped, projectDir: mapped.projectDir, conflictMode: mode)
                    importedAny = true
                } catch {
                    throw error
                }
            },
            onConflict: { info in
                await Self.promptSyncConflict(info)
            }
        )
        result.importedSessions = imported.count
        if importedAny {
            await refreshSessions()
        }

        // Agent JSONL mirror (pull + push of raw conversations). File I/O can
        // be heavy (large JSONL copies), so run it off the main actor and only
        // hop back to update the wait overlay's phase text.
        let phaseUpdater: @Sendable (String) -> Void = { [weak self] step in
            DispatchQueue.main.async { self?.syncPhase = .mirroring(detail: step) }
        }
        let counts: SessionSync.AgentMirrorCounts = await Task.detached(priority: .userInitiated) {
            SessionSync.runAgentMirror(onStep: phaseUpdater)
        }.value
        let mirror = counts
        result.agentExported = mirror.exported
        result.agentImported = mirror.imported
        result.agentConflicts = mirror.conflicts
        result.agentConflictFiles = mirror.conflictFiles
        if !mirror.conflictFiles.isEmpty {
            mirrorConflicts = mirror.conflictFiles
            showMirrorConflicts = true
        }
        return result
    }

    /// Surface the outcome of a manual sync. A no-op sync silently reporting
    /// "0 sessions" left users unsure whether anything happened, so the
    /// up-to-date case gets an explicit toast.
    func reportSyncResult(_ result: SyncNowResult) {
        var parts: [String] = []
        if result.exportedSessions > 0 || result.importedSessions > 0 {
            parts.append("\(result.exportedSessions) exported, \(result.importedSessions) imported")
        }
        if result.agentExported > 0 || result.agentImported > 0 {
            var agent = "\(result.agentExported) pushed, \(result.agentImported) pulled (agent)"
            if result.agentConflicts > 0 {
                agent += ", \(result.agentConflicts) conflict(s) kept local"
            }
            parts.append(agent)
        }
        if parts.isEmpty {
            showToast("Everything is up to date")
        } else {
            showToast("Sync complete — \(parts.joined(separator: " · "))")
        }
    }

    /// Modal prompt for a sync conflict (both this Mac and the cloud changed
    /// the same conversation since the last sync). There is no line-level
    /// merge, so the user decides which version wins.
    @MainActor
    static func promptSyncConflict(_ info: SessionSync.SyncConflictInfo) async -> SessionSync.SyncConflictChoice {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let remote = "Cloud: \(fmt.string(from: info.remoteModified))"
        let local = info.localModified.map { "This Mac: \(fmt.string(from: $0))" } ?? "This Mac: has unsynced changes"

        let alert = NSAlert()
        alert.messageText = "Sync conflict: \(info.sessionName)"
        alert.informativeText = """
            This conversation was modified on both this Mac and another device. \
            Only one version can be kept.

            \(local)
            \(remote)
            """
        alert.alertStyle = .warning
        // NSAlert lays buttons out right-to-left: the first addButton is the
        // rightmost default (Return key).
        alert.addButton(withTitle: "Use Cloud Version")
        alert.addButton(withTitle: "Import Cloud as New Session")
        alert.addButton(withTitle: "Keep This Mac's Version")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .useRemote
        case .alertSecondButtonReturn: return .importAsNew
        default: return .keepLocal
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
        // Settings: "Restore last selected session on launch" (default on).
        guard UserDefaults.standard.object(forKey: "lmux_restore_last_session") == nil ||
                UserDefaults.standard.bool(forKey: "lmux_restore_last_session") else {
            return
        }

        var entries = SessionRestore.loadAll()
        guard !entries.isEmpty else { return }

        // Only restore sessions that still exist in the backend. Entries left
        // behind for deleted sessions are dropped (and removed from
        // restore.json) so a deleted session never comes back after restart.
        let backendIDs = Set(sessions.map { $0.id })
        let stale = entries.filter { !backendIDs.contains($0.sessionID) }
        for entry in stale {
            SessionRestore.remove(sessionID: entry.sessionID)
        }
        entries.removeAll { !backendIDs.contains($0.sessionID) }
        guard !entries.isEmpty else { return }

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
