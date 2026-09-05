import Foundation
import LMUXCore

/// Cross-device session sync via a cloud-synced directory.
///
/// Pinned (starred) sessions are exported as `.lmuxsession` files into
/// `<syncDir>/sessions/<name>__<cbc8>.lmuxsession`. A background poll
/// (ContentViewModel) calls `applyIncrementalExport` and `importIfChanged`
/// each cycle. The directory is shared with other machines (iCloud Drive,
/// Syncthing, ...), so both directions propagate automatically.
///
/// Export is incremental: the backend returns only the JSONL bytes appended
/// after the last synchronized offset (`since`), and this module merges them
/// into the local sync copy before writing back. The full file is always
/// written locally, but the cloud only uploads the changed blocks.
///
/// Import detects new files by modification time (preserved by cloud sync);
/// a `device_id` inside each file prevents a machine from importing its own
/// exports (loop prevention).
enum SessionSync {
    // MARK: - Config (UserDefaults)

    private static let enabledKey = "lmux_sync_enabled"
    private static let syncDirKey = "lmux_sync_dir"
    private static let mappingsKey = "lmux_path_mappings"
    private static let deviceIDKey = "lmux_device_id"
    private static let offsetsKey = "lmux_sync_offsets"
    private static let importedMtimesKey = "lmux_sync_imported_mtimes"
    private static let agentMirrorEnabledKey = "lmux_agent_mirror_enabled"
    /// relpath -> "size,mtime" of the local JSONL last pushed to the mirror.
    private static let agentExportFpKey = "lmux_agent_export_fp"
    /// relpath -> size the local JSONL had when it was last pulled back from
    /// the mirror. Guards against re-export ping-pong: an agent JSONL cannot
    /// carry a device id, so we remember sizes instead.
    private static let agentImportedFpKey = "lmux_agent_import_fp"
    /// Files larger than this are skipped for the agent mirror (a whole
    /// iCloud-synced history this big would dominate the cloud folder).
    private static let agentMirrorMaxBytes: Int64 = 50 << 20

    /// Sync state lives in a shared UserDefaults suite so both app products —
    /// the ghostty build (`com.manshiangli.lmux`) and the SwiftTerm macOS 12
    /// build (`com.manshiangli.lmux-st`) — see the SAME sync directory, path
    /// mappings, device id and offsets. `UserDefaults.standard` is scoped to
    /// the bundle id, so the st variant would otherwise show an empty sync
    /// config (different Sync settings layout) from the master build.
    ///
    /// First access migrates any existing per-bundle values (from before the
    /// suite existed) into the shared domain.
    private static let defaults: UserDefaults = {
        let shared = UserDefaults(suiteName: "com.manshiangli.lmux.sync")!
        migrateLegacySyncState(into: shared)
        return shared
    }()

    /// Copy sync config written under an old per-bundle domain into the
    /// shared suite, once. Candidate domains: this bundle, then the canonical
    /// master bundle id (so a fresh st install inherits the master config).
    private static func migrateLegacySyncState(into shared: UserDefaults) {
        let alreadyHasData = shared.object(forKey: enabledKey) != nil
            || shared.string(forKey: syncDirKey) != nil
            || shared.string(forKey: deviceIDKey) != nil
        guard !alreadyHasData else { return }

        let candidates = [Bundle.main.bundleIdentifier, "com.manshiangli.lmux"].compactMap { $0 }
        for bid in candidates {
            guard let legacy = UserDefaults(suiteName: bid) else { continue }
            let hasConfig = legacy.object(forKey: enabledKey) != nil
                || legacy.string(forKey: syncDirKey) != nil
                || legacy.string(forKey: deviceIDKey) != nil
                || legacy.dictionary(forKey: offsetsKey) != nil
            guard hasConfig else { continue }
            for key in [enabledKey, syncDirKey, mappingsKey, deviceIDKey, offsetsKey, importedMtimesKey, agentMirrorEnabledKey, agentExportFpKey, agentImportedFpKey] {
                if let value = legacy.object(forKey: key) {
                    shared.set(value, forKey: key)
                }
            }
            break
        }
    }

    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    static var syncDir: String? {
        get { defaults.string(forKey: syncDirKey) }
        set { defaults.set(newValue, forKey: syncDirKey) }
    }

    static var pathMappings: [PathMapping] {
        get {
            guard let raw = defaults.array(forKey: mappingsKey) as? [[String]] else { return [] }
            return raw.compactMap { pair in
                guard pair.count == 2, !pair[0].isEmpty else { return nil }
                return PathMapping(from: pair[0], to: pair[1])
            }
        }
        set {
            let raw = newValue.map { [$0.from, $0.to] }
            defaults.set(raw, forKey: mappingsKey)
        }
    }

    static var deviceID: String {
        if let existing = defaults.string(forKey: deviceIDKey) {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIDKey)
        return id
    }

    // MARK: - Incremental sync state

    /// cbc_session_id -> byte offset up to which we have synchronized.
    /// Persisted so an incremental export resumes correctly after restart.
    private static var exportedOffsets: [String: Int64] {
        get {
            defaults.dictionary(forKey: offsetsKey) as? [String: Int64] ?? [:]
        }
        set {
            defaults.set(newValue, forKey: offsetsKey)
        }
    }

    /// The byte offset already exported for a conversation.
    static func exportedOffset(for cbcID: String) -> Int64 {
        exportedOffsets[cbcID] ?? 0
    }

    /// Clear the tracked offset for a conversation so the next export is a
    /// full resync. Used after the local sync copy was found missing and the
    /// caller will re-export the whole conversation.
    static func resetExportedOffset(for cbcID: String) {
        var offsets = exportedOffsets
        offsets[cbcID] = nil
        exportedOffsets = offsets
    }

    /// cbc_session_id -> last remote file mtime we imported. Persisted so a
    /// restart doesn't re-import every remote file (each import used to spawn
    /// a duplicate session under conflictMode "new"; with "overwrite" it
    /// would only refresh, but skipping is still cheaper and quieter).
    private static var lastImportedFileMtime: [String: TimeInterval] {
        get {
            defaults.dictionary(forKey: importedMtimesKey) as? [String: TimeInterval] ?? [:]
        }
        set {
            defaults.set(newValue, forKey: importedMtimesKey)
        }
    }

    // MARK: - Path mapping

    /// Apply the configured path mappings (longest prefix first) to a path or
    /// text blob containing absolute paths (e.g. project_dir, JSONL cwd).
    static func applyPathMappings(_ text: String) -> String {
        SyncPathMapping.apply(text, mappings: pathMappings)
    }

    // MARK: - File helpers

    static func sessionsDir() -> URL? {
        guard let dir = syncDir else { return nil }
        return URL(fileURLWithPath: dir).appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - Agent JSONL mirror

    /// Mirror root inside the sync dir: `<syncDir>/agents/<agentName>`.
    static func agentsDir(agentName: String) -> URL? {
        guard let dir = syncDir else { return nil }
        return URL(fileURLWithPath: dir).appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentName, isDirectory: true)
    }

    /// Master toggle for mirroring raw agent JSONL to the sync directory.
    static var agentMirrorEnabled: Bool {
        get { defaults.bool(forKey: agentMirrorEnabledKey) }
        set { defaults.set(newValue, forKey: agentMirrorEnabledKey) }
    }

    /// Outcome of one agent-mirror pass.
    struct AgentMirrorCounts {
        var exported = 0
        var imported = 0
        var conflicts = 0
        var isActive = false
    }

    /// One full mirror pass: push local agent JSONL out to the cloud mirror,
    /// then pull back anything the mirror has that we don't. Returns what
    /// happened (for Sync Now reporting). No-op when disabled or unsynced.
    @discardableResult
    static func runAgentMirror() -> AgentMirrorCounts {
        var counts = AgentMirrorCounts()
        guard agentMirrorEnabled, syncDir != nil else { return counts }
        counts.isActive = true

        for agentName in ["codebuddy", "claude"] {
            guard let localRoot = localRoot(agentName: agentName),
                  let mirror = agentsDir(agentName: agentName) else { continue }
            if !FileManager.default.fileExists(atPath: mirror.path) {
                try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
            }
            let e = mirrorExport(agentName: agentName, localRoot: localRoot, mirrorRoot: mirror)
            counts.exported += e
            let imp = mirrorImport(agentName: agentName, localRoot: localRoot, mirrorRoot: mirror)
            counts.imported += imp.imported
            counts.conflicts += imp.conflicts
        }
        return counts
    }

    private static func localRoot(agentName: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch agentName {
        case "claude":
            return home.appendingPathComponent(".claude/projects", isDirectory: true)
        default:
            return home.appendingPathComponent(".codebuddy/projects", isDirectory: true)
        }
    }

    private static func agentExportFps() -> [String: String] {
        defaults.dictionary(forKey: agentExportFpKey) as? [String: String] ?? [:]
    }
    private static func setAgentExportFps(_ fps: [String: String]) {
        defaults.set(fps, forKey: agentExportFpKey)
    }
    private static func agentImportedFps() -> [String: Int64] {
        defaults.dictionary(forKey: agentImportedFpKey) as? [String: Int64] ?? [:]
    }
    private static func setAgentImportedFps(_ fps: [String: Int64]) {
        defaults.set(fps, forKey: agentImportedFpKey)
    }

    /// Push local JSONL that changed since the last export (or that we did not
    /// just pull back) into the mirror. Appends the tail when the mirror copy
    /// already exists (agent JSONL is append-only), else copies whole.
    private static func mirrorExport(agentName: String, localRoot: URL, mirrorRoot: URL) -> Int {
        var fps = agentExportFps()
        var imported = agentImportedFps()
        var exported = 0

        guard let files = enumerateJSONL(under: localRoot) else { return 0 }
        for local in files {
            let rel = String(local.path.dropFirst(localRoot.path.count).drop(while: { $0 == "/" }))
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let mod = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            guard size <= agentMirrorMaxBytes else { continue }

            // Loop guard: never re-push a file whose current size is exactly
            // what we pulled back from the mirror (nothing new locally).
            if size <= (imported[rel] ?? 0) { continue }
            // Unchanged since last export → skip.
            if fps[rel] == "\(size),\(Int(mod))" { continue }

            let mirrorFile = mirrorRoot.appendingPathComponent(rel)
            do {
                try FileManager.default.createDirectory(at: mirrorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                let mirrorSize = (try? FileManager.default.attributesOfItem(atPath: mirrorFile.path)[.size] as? NSNumber)?.int64Value ?? 0
                if mirrorSize > 0, mirrorSize < size {
                    // Append-only growth: copy just the new tail.
                    let handle = try FileHandle(forWritingTo: mirrorFile)
                    try handle.seekToEnd()
                    let reader = try FileHandle(forReadingFrom: local)
                    try reader.seek(toOffset: UInt64(mirrorSize))
                    if let tail = try reader.readToEnd() {
                        try handle.write(contentsOf: tail)
                    }
                    try handle.close()
                    try reader.close()
                } else {
                    // Fresh copy (whole file) when no mirror or mirror is not a
                    // strict prefix of local (different machine content).
                    if FileManager.default.fileExists(atPath: mirrorFile.path) {
                        try FileManager.default.removeItem(at: mirrorFile)
                    }
                    try FileManager.default.copyItem(at: local, to: mirrorFile)
                }
                fps[rel] = "\(size),\(Int(mod))"
                exported += 1
            } catch {
                NSLog("agent mirror export %@: %@", rel, error.localizedDescription)
            }
        }
        if !fps.isEmpty { setAgentExportFps(fps) }
        return exported
    }

    /// Pull mirror JSONL back into the local agent projects root.
    /// - Local missing → whole copy.
    /// - Local grew since its last pull-back (this machine kept working) and
    ///   the mirror is bigger still → conflict: keep local (the export pass
    ///   will push our new tail next run) and count it.
    /// - Local is an older version of the mirror (mirror is strictly longer
    ///   and local hasn't changed since its last pull) → append the tail.
    private static func mirrorImport(agentName: String, localRoot: URL, mirrorRoot: URL) -> (imported: Int, conflicts: Int) {
        var imported = agentImportedFps()
        var importedCount = 0
        var conflicts = 0

        guard let files = enumerateJSONL(under: mirrorRoot) else { return (0, 0) }
        for mirror in files {
            let rel = String(mirror.path.dropFirst(mirrorRoot.path.count).drop(while: { $0 == "/" }))
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: mirror.path),
                  let remoteSize = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            guard remoteSize <= agentMirrorMaxBytes else { continue }

            let local = localRoot.appendingPathComponent(rel)
            let lastPullSize = imported[rel]
            let localSize = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0

            if localSize == 0 {
                // Not here yet — copy the mirror copy home.
                do {
                    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: mirror, to: local)
                    imported[rel] = remoteSize
                    importedCount += 1
                } catch {
                    NSLog("agent mirror import %@: %@", rel, error.localizedDescription)
                }
            } else if let lastPullSize, localSize == lastPullSize, remoteSize > localSize {
                // Local unchanged since we last pulled; mirror advanced → append.
                do {
                    let handle = try FileHandle(forWritingTo: local)
                    try handle.seekToEnd()
                    let reader = try FileHandle(forReadingFrom: mirror)
                    try reader.seek(toOffset: UInt64(localSize))
                    if let tail = try reader.readToEnd() {
                        try handle.write(contentsOf: tail)
                    }
                    try handle.close()
                    try reader.close()
                    imported[rel] = remoteSize
                    importedCount += 1
                } catch {
                    NSLog("agent mirror append %@: %@", rel, error.localizedDescription)
                }
            } else if remoteSize > localSize {
                // This machine kept writing (localSize > lastPullSize) AND the
                // mirror also grew → two-way change. Keep local; export pass
                // pushes our tail next run. Count so Sync Now can tell.
                conflicts += 1
            }
            // remoteSize <= localSize → local is newer/equal; export handles it.
        }
        if !imported.isEmpty { setAgentImportedFps(imported) }
        return (importedCount, conflicts)
    }

    /// All top-level conversation files under a directory (one level deep,
    /// matching the backend's file_rel layout). Deeper JSONL (subagents/,
    /// task sub-conversations) is agent-internal and not part of the mirror.
    private static func enumerateJSONL(under root: URL) -> [URL]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        var files: [URL] = []
        for entry in entries {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                // One level down: encoded project dir -> conversation JSONL.
                if let inner = try? FileManager.default.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil
                ) {
                    for file in inner where file.pathExtension == "jsonl" {
                        files.append(file)
                    }
                }
            } else if entry.pathExtension == "jsonl" {
                // Files directly under the root.
                files.append(entry)
            }
        }
        files.sort { $0.path < $1.path }
        return files
    }

    /// Ensure the conversation's JSONL exists locally. When it is missing,
    /// pull it back from the sync mirror (M2 keeps an agent JSONL mirror next
    /// to the .lmuxsession exports) so `agent --resume <id>` can find it.
    /// No-op when there is no mirror copy or the local file already exists.
    ///
    /// `fileRel` is the file's path relative to the agent projects root as
    /// reported by the backend (mirror layout matches it). Falls back to the
    /// encoded projectDir for older backends that lack `file_rel`.
    static func restoreAgentFileIfMissing(agentName: String, sessionID: String, fileRel: String?, projectDir: String) {
        let localRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(agentName == "claude" ? ".claude/projects" : ".codebuddy/projects", isDirectory: true)
        let subpath: String
        if let fileRel, !fileRel.isEmpty {
            subpath = fileRel
        } else {
            subpath = "\(encodedProjectDir(agentType: agentName, projectDir: projectDir))/\(sessionID).jsonl"
        }

        let local = localRoot.appendingPathComponent(subpath)
        guard !FileManager.default.fileExists(atPath: local.path) else { return }
        guard let mirrorRoot = agentsDir(agentName: agentName) else { return }
        let mirrorFile = mirrorRoot.appendingPathComponent(subpath)
        guard FileManager.default.fileExists(atPath: mirrorFile.path) else { return }
        do {
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: mirrorFile, to: local)
        } catch {
            NSLog("restoreAgentFileIfMissing: %@", error.localizedDescription)
        }
    }

    /// Build a human-readable sync file name: `<name>__<cbc8>.lmuxsession`.
    static func syncFileName(name: String, cbcID: String) -> String {
        let clean = SyncPathMapping.sanitizeFileName(name)
        let short = String(cbcID.prefix(8))
        let base = clean.isEmpty ? short : "\(clean)__\(short)"
        return "\(base).lmuxsession"
    }

    /// Find the sync file for a conversation by scanning the directory for a
    /// bundle whose cbc_session_id matches (file names are human-readable and
    /// can change with renames).
    static func fileURL(for cbcID: String) -> URL? {
        guard let dir = sessionsDir() else { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for file in files where file.pathExtension == "lmuxsession" {
            guard let bundle = SessionExportBundle.fromJSON(file) else { continue }
            if bundle.cbcSessionID == cbcID {
                return file
            }
        }
        return nil
    }

    // MARK: - Export

    enum IncrementalExportResult {
        case updated
        case unchanged
        case needsFullExport
    }

    /// Merge an incremental export (content = appended JSONL after the last
    /// synchronized offset, offset = new total size) into the local sync copy.
    ///
    /// Returns `.needsFullExport` when there is no matching local copy to
    /// append to (e.g. first run or the file was removed); the caller should
    /// re-export with `since: 0`.
    static func applyIncrementalExport(_ bundle: SessionExportBundle) -> IncrementalExportResult {
        guard let dir = sessionsDir() else { return .needsFullExport }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .needsFullExport
        }

        let cbcID = bundle.cbcSessionID
        let localOffset = exportedOffset(for: cbcID)
        let newOffset = bundle.offset ?? 0

        let foundURL = fileURL(for: cbcID)
        let existing = foundURL.flatMap { SessionExportBundle.fromJSON($0) }

        // Pure decision logic (unit-tested in LMUXCore).
        switch SyncIncrement.decide(
            hasLocalFile: foundURL != nil,
            localOffset: localOffset,
            newOffset: newOffset,
            localFileOffsetMatches: existing?.offset == localOffset
        ) {
        case .unchanged:
            return .unchanged
        case .needsFullExport:
            // Local copy missing (deleted) or offsets inconsistent — resync.
            return .needsFullExport
        case .append, .freshExport:
            break // handled below
        }

        let freshName = syncFileName(name: bundle.name, cbcID: cbcID)
        var url: URL
        if let foundURL {
            url = foundURL
            // Migrate legacy "//__xxxx.lmuxsession" names from earlier sync
            // versions to the human-readable "<name>__<cbc8>.lmuxsession".
            let foundName = foundURL.lastPathComponent
            if foundName != freshName, foundName.hasPrefix("__"), foundName == "__\(String(cbcID.prefix(8))).lmuxsession" {
                let target = foundURL.deletingLastPathComponent().appendingPathComponent(freshName)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try? FileManager.default.moveItem(at: foundURL, to: target)
                    url = target
                }
            }
        } else {
            url = dir.appendingPathComponent(freshName)
        }

        var merged = bundle
        merged.deviceId = deviceID
        merged.offset = newOffset

        if let existing, existing.offset == localOffset {
            // Append the increment to the existing local copy.
            merged.content = existing.content + bundle.content
            merged.name = existing.name // keep the original display name
        } else {
            // Fresh export: content already holds the full conversation.
            merged.content = bundle.content
        }

        do {
            try merged.toJSON().write(to: url, options: .atomic)
            var offsets = exportedOffsets
            offsets[cbcID] = newOffset
            exportedOffsets = offsets
            return .updated
        } catch {
            return .needsFullExport
        }
    }

    /// Remove the sync copy of a session that is no longer pinned. Deleting is
    /// NOT propagated across devices (per design); this only clears local
    /// tracking state.
    static func forgetPinnedExport(_ cbcID: String) {
        var offsets = exportedOffsets
        offsets[cbcID] = nil
        exportedOffsets = offsets
        lastImportedFileMtime[cbcID] = nil
    }

    // MARK: - Import

    /// What to do when both sides modified the same conversation since the
    /// last sync (there is no line-level merge; the user decides).
    enum SyncConflictChoice {
        /// Keep this Mac's version: skip the import and mark the remote file
        /// processed so the prompt does not reappear on every sync.
        case keepLocal
        /// Overwrite the local conversation with the cloud version.
        case useRemote
        /// Import the cloud version as a separate session (new session id).
        case importAsNew
    }

    /// Context shown to the user when a sync conflict is detected.
    struct SyncConflictInfo {
        let cbcSessionID: String
        let sessionName: String
        let agentType: String
        let remoteModified: Date
        let localModified: Date?
    }

    /// codebuddy encodes a project dir without the leading slash
    /// (/Users/x -> Users-x); claude keeps it (-Users-x).
    static func encodedProjectDir(agentType: String, projectDir: String) -> String {
        if agentType == "claude" {
            return projectDir.replacingOccurrences(of: "/", with: "-")
        }
        var s = projectDir
        if s.hasPrefix("/") { s.removeFirst() }
        return s.replacingOccurrences(of: "/", with: "-")
    }

    /// Local JSONL file for a conversation, or nil when it does not exist.
    static func localJSONLURL(agentType: String, cbcID: String, projectDir: String) -> URL? {
        let root = agentType == "claude" ? ".claude/projects" : ".codebuddy/projects"
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "\(root)/\(encodedProjectDir(agentType: agentType, projectDir: projectDir))/\(cbcID).jsonl"
        )
    }

    /// True when the local JSONL has grown past the offset we last pushed to
    /// the cloud — i.e. this Mac has conversation changes that the remote
    /// file cannot contain. Used to detect a two-sided edit (sync conflict).
    static func hasUnsyncedLocalChanges(agentType: String, cbcID: String, projectDir: String) -> Bool {
        guard let url = localJSONLURL(agentType: agentType, cbcID: cbcID, projectDir: projectDir),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return Int64(size) > exportedOffset(for: cbcID)
    }

    /// Scan the sync directory and import any remote file that is newer than
    /// the last one processed. `importBundle` performs the actual backend
    /// import (mode is "overwrite", or "new" when the user chooses to keep
    /// both versions) and returns the imported session's id (or throws).
    /// `onConflict` is consulted when both sides changed the same
    /// conversation; returning nil lets the caller skip that file entirely.
    /// Returns the list of imported cbc ids.
    static func importIfChanged(
        importBundle: (SessionExportBundle, String) async throws -> Void,
        onConflict: ((SyncConflictInfo) async -> SyncConflictChoice)? = nil
    ) async -> [String] {
        guard let dir = sessionsDir() else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var imported: [String] = []
        for file in files where file.pathExtension == "lmuxsession" {
            guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            guard let bundle = SessionExportBundle.fromJSON(file) else { continue }
            let cbcID = bundle.cbcSessionID

            // Skip files already processed at this (or newer) mtime.
            if let last = lastImportedFileMtime[cbcID], mtime.timeIntervalSince1970 <= last {
                continue
            }
            // Never import our own exports (loop prevention).
            if bundle.deviceId == deviceID { continue }

            var mode = "overwrite"
            // Two-sided edit: the remote file changed AND this Mac has local
            // conversation changes that were never pushed. Overwriting would
            // silently destroy one side, so ask the user instead.
            if hasUnsyncedLocalChanges(
                agentType: bundle.agentType,
                cbcID: cbcID,
                projectDir: bundle.projectDir) {
                guard let onConflict else { continue }
                let info = SyncConflictInfo(
                    cbcSessionID: cbcID,
                    sessionName: bundle.name,
                    agentType: bundle.agentType,
                    remoteModified: mtime,
                    localModified: nil)
                let choice = await onConflict(info)
                switch choice {
                case .keepLocal:
                    lastImportedFileMtime[cbcID] = mtime.timeIntervalSince1970
                    continue
                case .useRemote:
                    mode = "overwrite"
                case .importAsNew:
                    mode = "new"
                }
            }

            do {
                try await importBundle(bundle, mode)
                lastImportedFileMtime[cbcID] = mtime.timeIntervalSince1970
                imported.append(cbcID)
            } catch {
                // Import failed (bad path mapping, corrupt file): skip it, but
                // don't mark processed so a later attempt can retry.
                continue
            }
        }
        return imported
    }

    // MARK: - Testing support

    /// Reset in-memory and persisted state (tests).
    static func resetStateForTesting() {
        defaults.removeObject(forKey: offsetsKey)
        defaults.removeObject(forKey: importedMtimesKey)
    }
}
