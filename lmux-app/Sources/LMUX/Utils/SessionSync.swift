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
    /// cbc_session_id -> the source byte offset the local sync copy's content
    /// starts at, i.e. the compaction base it was written against.
    ///
    /// Kept here rather than inside the `.lmuxsession` because it is a byte
    /// offset into this machine's file: on another machine the same number
    /// describes nothing, and a copy that was written elsewhere must be rebuilt
    /// rather than extended.
    private static let basesKey = "lmux_sync_bases"
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

    /// cbc_session_id -> the compaction base the local sync copy was written
    /// against. Persisted with the offsets above, and for the same reason: both
    /// are byte offsets into this machine's conversation file, so losing them
    /// costs one rebuild while inventing them would corrupt the copy.
    private static var syncBases: [String: Int64] {
        get {
            defaults.dictionary(forKey: basesKey) as? [String: Int64] ?? [:]
        }
        set {
            defaults.set(newValue, forKey: basesKey)
        }
    }

    /// The `since` offset to request for the next incremental export.
    ///
    /// The persisted tracking can be lost or lag behind (defaults migration,
    /// resets) while the mirror `.lmuxsession` on disk is further along. The
    /// merge decision in `applyIncrementalExport` heals from the file's
    /// recorded offset — the request must use the same basis, or the server
    /// returns bytes the mirror already contains and appending them
    /// duplicates the whole conversation. So: max(tracked, file offset) — but
    /// only when that file is ours. Another device's copy counts bytes of a
    /// different file, and asking from its offset makes the backend answer with
    /// a slice this machine never wrote.
    static func exportSinceOffset(for cbcID: String) -> Int64 {
        // Read the copy once: decoding one asks lzfse to expand a payload that
        // can be tens of megabytes.
        let mirror = mirrorBundle(for: cbcID)?.bundle
        return SyncIncrement.requestSinceOffset(
            tracked: exportedOffset(for: cbcID),
            mirrorOffset: mirror?.offset,
            mirrorOwnedByThisDevice: mirror?.deviceId == deviceID)
    }

    /// The source offset the local sync copy's content begins at (its
    /// compaction base). 0 for a copy that holds the conversation from its
    /// first record — every copy written before compaction trimming existed,
    /// and every conversation that was never compacted.
    static func syncBase(for cbcID: String) -> Int64 {
        syncBases[cbcID] ?? 0
    }

    /// Record the base of the content just written to the sync copy.
    static func recordSyncBase(_ base: Int64, for cbcID: String) {
        var bases = syncBases
        bases[cbcID] = base
        syncBases = bases
    }

    /// Clear the tracked offset for a conversation so the next export is a
    /// full resync. Used after the local sync copy was found missing and the
    /// caller will re-export the whole conversation.
    static func resetExportedOffset(for cbcID: String) {
        var offsets = exportedOffsets
        offsets[cbcID] = nil
        exportedOffsets = offsets
    }

    /// Record how far this conversation has been synchronized. Used after an
    /// import, to line the tracking up with the content just taken.
    static func recordExportedOffset(_ offset: Int64, for cbcID: String) {
        var offsets = exportedOffsets
        offsets[cbcID] = offset
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
        var conflictFiles: [AgentMirrorConflict] = []
        var isActive = false
    }

    /// A two-way change on one conversation file: both this machine and the
    /// mirror grew since the last sync. Surfaced for the user to resolve.
    struct AgentMirrorConflict: Identifiable {
        let agentName: String
        let fileRel: String
        let localSize: Int64
        let localMTime: Int64
        let remoteSize: Int64
        let remoteMTime: Int64

        var id: String { "\(agentName)|\(fileRel)" }
    }

    /// One full mirror pass: push local agent JSONL out to the cloud mirror,
    /// then pull back anything the mirror has that we don't. Returns what
    /// happened (for Sync Now reporting). No-op when disabled or unsynced.
    /// `onStep` is invoked before each direction/agent so the UI can show
    /// live progress.
    @discardableResult
    static func runAgentMirror(onStep: ((String) -> Void)? = nil) -> AgentMirrorCounts {
        var counts = AgentMirrorCounts()
        guard agentMirrorEnabled, syncDir != nil else { return counts }
        counts.isActive = true

        for agentName in ["codebuddy", "claude"] {
            guard let localRoot = localRoot(agentName: agentName),
                  let mirror = agentsDir(agentName: agentName) else { continue }
            if !FileManager.default.fileExists(atPath: mirror.path) {
                try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
            }
            onStep?("Export \(displayName(agentName))")
            let e = mirrorExport(agentName: agentName, localRoot: localRoot, mirrorRoot: mirror)
            counts.exported += e
            onStep?("Import \(displayName(agentName))")
            let imp = mirrorImport(agentName: agentName, localRoot: localRoot, mirrorRoot: mirror)
            counts.imported += imp.imported
            counts.conflicts += imp.conflicts.count
            counts.conflictFiles.append(contentsOf: imp.conflicts)
        }
        return counts
    }

    private static func displayName(_ agentName: String) -> String {
        agentName == "claude" ? "Claude" : "CodeBuddy"
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

            let mirrorFile = mirrorRoot.appendingPathComponent(rel)
            let mirrorExists = FileManager.default.fileExists(atPath: mirrorFile.path)
            let mirrorSize = mirrorExists
                ? ((try? FileManager.default.attributesOfItem(atPath: mirrorFile.path)[.size] as? NSNumber)?.int64Value ?? 0)
                : 0

            let action = AgentMirrorPolicy.exportAction(.init(
                localSize: size,
                localMTime: Int64(mod),
                mirrorExists: mirrorExists,
                mirrorSize: mirrorSize,
                lastExportFingerprint: fps[rel],
                lastImportSize: imported[rel]
            ))
            switch action {
            case .copyToMirror, .appendToMirror:
                do {
                    try FileManager.default.createDirectory(at: mirrorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if action == .appendToMirror {
                        // Append-only growth: copy just the new tail.
                        try AgentMirrorIO.appendTail(from: local, to: mirrorFile, fromOffset: mirrorSize)
                    } else {
                        // Fresh copy (whole file) when no mirror exists or the
                        // mirror is not a strict prefix (other machine content).
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
            case .skip, .copyToLocal, .appendToLocal, .conflictKeepLocal:
                continue
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
    private static func mirrorImport(agentName: String, localRoot: URL, mirrorRoot: URL) -> (imported: Int, conflicts: [AgentMirrorConflict]) {
        var imported = agentImportedFps()
        var importedCount = 0
        var conflicts: [AgentMirrorConflict] = []

        guard let files = enumerateJSONL(under: mirrorRoot) else { return (0, []) }
        for mirror in files {
            let rel = String(mirror.path.dropFirst(mirrorRoot.path.count).drop(while: { $0 == "/" }))
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: mirror.path),
                  let remoteSize = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            guard remoteSize <= agentMirrorMaxBytes else { continue }

            let local = localRoot.appendingPathComponent(rel)
            let localExists = FileManager.default.fileExists(atPath: local.path)
            let localAttrs = try? FileManager.default.attributesOfItem(atPath: local.path)
            let localSize = localExists ? ((localAttrs?[.size] as? NSNumber)?.int64Value ?? 0) : 0
            let localMTime = Int64((localAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            let remoteMTime = Int64((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)

            let action = AgentMirrorPolicy.importAction(.init(
                localExists: localExists,
                localSize: localSize,
                lastImportSize: imported[rel],
                remoteSize: remoteSize
            ))
            switch action {
            case .copyToLocal:
                do {
                    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: mirror, to: local)
                    imported[rel] = remoteSize
                    importedCount += 1
                } catch {
                    NSLog("agent mirror import %@: %@", rel, error.localizedDescription)
                }
            case .appendToLocal:
                do {
                    // Local unchanged since we last pulled; mirror advanced → append.
                    try AgentMirrorIO.appendTail(from: mirror, to: local, fromOffset: localSize)
                    imported[rel] = remoteSize
                    importedCount += 1
                } catch {
                    NSLog("agent mirror append %@: %@", rel, error.localizedDescription)
                }
            case .conflictKeepLocal:
                // This machine kept writing AND the mirror also grew → two-way
                // change. Keep local (the export pass pushes our tail next
                // run) and record it so the UI can let the user resolve it.
                conflicts.append(AgentMirrorConflict(
                    agentName: agentName,
                    fileRel: rel,
                    localSize: localSize,
                    localMTime: localMTime,
                    remoteSize: remoteSize,
                    remoteMTime: remoteMTime
                ))
            case .skip, .copyToMirror, .appendToMirror:
                continue
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

    /// Resolve a two-way mirror conflict by replacing the local file with the
    /// mirror copy. Bookkeeping is updated so the next export pass does not
    /// push the old local content back (or re-import the same file).
    /// Returns false when either side is missing.
    static func resolveMirrorConflict(agentName: String, fileRel: String) -> Bool {
        guard let localRoot = localRoot(agentName: agentName),
              let mirrorRoot = agentsDir(agentName: agentName) else { return false }
        let local = localRoot.appendingPathComponent(fileRel)
        let mirror = mirrorRoot.appendingPathComponent(fileRel)
        guard FileManager.default.fileExists(atPath: mirror.path) else { return false }

        do {
            if FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.removeItem(at: local)
            }
            try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: mirror, to: local)

            // Local is now exactly the mirror copy: remember it as "imported"
            // so the export loop guard suppresses re-pushing it, and drop the
            // old export fingerprint so the bookkeeping matches reality.
            let attrs = try FileManager.default.attributesOfItem(atPath: local.path)
            let newSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            var imported = agentImportedFps()
            imported[fileRel] = newSize
            setAgentImportedFps(imported)
            var fps = agentExportFps()
            fps.removeValue(forKey: fileRel)
            setAgentExportFps(fps)
            return true
        } catch {
            NSLog("resolveMirrorConflict %@/%@: %@", agentName, fileRel, error.localizedDescription)
            return false
        }
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

    /// Find the sync file for a conversation and hand back its decoded bundle.
    ///
    /// This used to decode every `.lmuxsession` in the directory to compare
    /// `cbc_session_id`, and the caller then decoded the match a second time.
    /// With payload compression the first pass expands the whole conversation
    /// text of every long session into memory — a couple of hundred megabytes
    /// per sync — to answer a question the file name already answers.
    ///
    /// `syncFileName` always ends the name with the conversation's first eight
    /// id characters, so that narrows the search to one candidate; the decode
    /// that follows doubles as the confirmation, and only a name that is not
    /// the one we expect (renamed by hand, or written by a version with a
    /// different naming rule) falls back to reading them all.
    static func mirrorBundle(for cbcID: String) -> (url: URL, bundle: SessionExportBundle)? {
        guard let dir = sessionsDir() else { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let mirrors = files.filter { $0.pathExtension == "lmuxsession" }

        // "<name>__<cbc8>.lmuxsession", plus the nameless form syncFileName
        // falls back to when the session name sanitizes away.
        let short = String(cbcID.prefix(8))
        let named = mirrors.filter {
            let name = $0.lastPathComponent
            return name.hasSuffix("__\(short).lmuxsession") || name == "\(short).lmuxsession"
        }
        // Candidates in order, so the loop below reads each file exactly once:
        // the name match first, then everything else for the fallback scan.
        for file in named + mirrors.filter({ !named.contains($0) }) {
            if let bundle = SessionExportBundle.fromJSON(file), bundle.cbcSessionID == cbcID {
                return (file, bundle)
            }
        }
        return nil
    }

    /// The stored form of a mirror: the size on disk and the length of the text
    /// it holds, as read from the file's attributes and the decoded bundle.
    private struct StoredSize {
        let fileBytes: Int64
        let contentBytes: Int64
    }

    /// Read the two sizes `needsReencode` judges, so the caller does not stat
    /// the same file again.
    private static func storedSize(url: URL, bundle: SessionExportBundle) -> StoredSize? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileBytes = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        return StoredSize(fileBytes: fileBytes, contentBytes: Int64(bundle.content.utf8.count))
    }

    /// True when a mirror is still stored uncompressed although its payload is
    /// large enough to compress.
    ///
    /// An unchanged conversation never rewrites its mirror, so a copy written
    /// before payload compression existed would keep its full size forever.
    ///
    /// The two stored forms cannot be confused by size alone. Plain, the file
    /// is *larger* than the text it holds — JSON escaping only ever adds bytes.
    /// Compressed, it is about an eighth. So anything at or above the text
    /// length is plain, and everything below it is not: there is no band in
    /// between for a payload to hide in.
    private static func needsReencode(_ size: StoredSize) -> Bool {
        guard size.contentBytes >= SyncPayloadCompression.minimumBytes else { return false }
        return size.fileBytes >= size.contentBytes
    }

    // MARK: - Export

    enum IncrementalExportResult {
        case updated
        case unchanged
        case needsFullExport
    }

    /// Merge an export bundle (content = the source's bytes from the requested
    /// offset, offset = the source's total size) into the local sync copy.
    ///
    /// The copy holds `source[base:]`, where `base` is the start of the
    /// conversation's last compaction boundary — everything before it is text
    /// the CLI no longer reads. Returns `.needsFullExport` when the bundle
    /// cannot stand in for that whole range: there is no copy to append to, a
    /// compaction moved the boundary, or the copy was written by another device.
    /// The caller re-exports from zero, which the backend answers from the base.
    static func applyIncrementalExport(_ bundle: SessionExportBundle) -> IncrementalExportResult {
        guard let dir = sessionsDir() else { return .needsFullExport }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .needsFullExport
        }

        let cbcID = bundle.cbcSessionID
        let found = mirrorBundle(for: cbcID)
        let foundURL = found?.url
        let existing = found?.bundle

        // Pure decision logic (unit-tested in LMUXCore).
        let plan = SyncIncrement.plan(
            hasMirror: foundURL != nil,
            mirrorOwnedByThisDevice: existing?.deviceId == deviceID,
            mirrorOffset: existing?.offset ?? 0,
            mirrorContentBytes: existing.map { Int64($0.content.utf8.count) } ?? 0,
            knownBase: syncBase(for: cbcID),
            trackedOffset: exportedOffset(for: cbcID),
            incomingBase: bundle.base ?? 0,
            incomingContentStart: bundle.contentStart ?? 0,
            incomingBytes: Int64(bundle.content.utf8.count),
            newOffset: bundle.offset ?? 0,
            incomingEqualsMirror: existing?.content == bundle.content)

        switch plan {
        case .needsFullExport:
            // Not a failure: the caller re-exports from zero and gets back a
            // bundle covering the whole range. Logged because a conversation
            // that lands here on every pass is exactly the stall this layer has
            // produced before (an offset ahead of the file, a copy written
            // elsewhere), and the numbers say which.
            NSLog("lmux sync: %@ needs a base-relative re-export (base=%lld tracked=%lld mirror=%lld content=%lld)",
                  cbcID, bundle.base ?? 0, exportedOffset(for: cbcID),
                  existing?.offset ?? 0, Int64(bundle.content.utf8.count))
            return .needsFullExport
        case .unchanged:
            return reencodeIfStillPlain(foundURL: foundURL, existing: existing)
        case .append, .replace:
            break
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
        if plan == .append, let existing {
            // Append the increment, keeping the original display name and the
            // offset the copy's content already starts at.
            merged.content = existing.content + bundle.content
            merged.name = existing.name
            merged.base = existing.base
            merged.contentStart = existing.contentStart
        } else {
            // A fresh, rebuilt, or other device's copy: the bundle holds the
            // whole range the copy has to cover.
            merged.content = bundle.content
        }

        do {
            try merged.toJSON().write(to: url, options: .atomic)
            var offsets = exportedOffsets
            offsets[cbcID] = merged.offset ?? 0
            exportedOffsets = offsets
            recordSyncBase(merged.base ?? 0, for: cbcID)
            return .updated
        } catch {
            return .needsFullExport
        }
    }

    /// Migration, not a merge: a copy written before payload compression existed
    /// never shrinks on its own, because an unchanged conversation never rewrites
    /// the file — it would sit at its original size for as long as the session
    /// stays idle. Re-encode it once, in place, from the copy already in hand
    /// (its own metadata is the correct one here: the incoming bundle has nothing
    /// new to say about it).
    private static func reencodeIfStillPlain(
        foundURL: URL?, existing: SessionExportBundle?
    ) -> IncrementalExportResult {
        guard let foundURL, let existing,
              let size = storedSize(url: foundURL, bundle: existing),
              needsReencode(size) else { return .unchanged }

        // Read before the write: the content does not change, so the
        // modification date is put back afterwards. A newer one reads as "the
        // remote file changed" on the other machine and drags it into a needless
        // re-import (or a conflict prompt against whatever it has locally). It
        // re-encodes its own copy on its own next sync.
        let previousDate = (try? FileManager.default
            .attributesOfItem(atPath: foundURL.path)[.modificationDate]) as? Date
        do {
            let encoded = try existing.toJSON()
            // Only take the new form when it is genuinely smaller: a payload that
            // compresses badly would otherwise be rewritten on every single sync,
            // forever.
            if Int64(encoded.count) >= size.fileBytes { return .unchanged }
            try encoded.write(to: foundURL, options: .atomic)
            if let previousDate {
                try? FileManager.default.setAttributes(
                    [.modificationDate: previousDate], ofItemAtPath: foundURL.path)
            }
            return .updated
        } catch {
            // Leave it as it is: the copy is intact, just large.
            return .unchanged
        }
    }

    /// Remove the sync copy of a session that is no longer pinned. Deleting is
    /// NOT propagated across devices (per design); this only clears local
    /// tracking state.
    static func forgetPinnedExport(_ cbcID: String) {
        var offsets = exportedOffsets
        offsets[cbcID] = nil
        exportedOffsets = offsets
        var bases = syncBases
        bases[cbcID] = nil
        syncBases = bases
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

    /// True when the sync copy's records stop after this Mac's — the other
    /// machine has history this one does not, so publishing this Mac's copy
    /// would delete it (and the other machine would publish its own back).
    static func mirrorIsAheadOfLocal(agentType: String, cbcID: String, projectDir: String) -> Bool {
        guard let mirror = mirrorBundle(for: cbcID)?.bundle,
              let url = localJSONLURL(agentType: agentType, cbcID: cbcID, projectDir: projectDir),
              let localLast = lastTimestampInFile(url) else {
            return false
        }
        return SyncImport.cloudIsAheadOfLocal(
            localLast: localLast,
            cloudLast: SyncImport.lastRecordTimestamp(in: mirror.content))
    }

    /// True when the cloud copy's records stop before this Mac's do — an older
    /// copy of the same conversation, which must not be imported over it.
    static func cloudIsBehindLocal(agentType: String, cbcID: String,
                                   projectDir: String, incoming: String) -> Bool {
        guard let url = localJSONLURL(agentType: agentType, cbcID: cbcID, projectDir: projectDir),
              let localLast = lastTimestampInFile(url) else {
            return false
        }
        return SyncImport.cloudIsBehindLocal(
            localLast: localLast,
            cloudLast: SyncImport.lastRecordTimestamp(in: incoming))
    }

    /// The newest record timestamp in a local conversation, read from its tail:
    /// records are appended, so the newest one is at the end, and a bounded read
    /// keeps a hundred-megabyte history cheap. Nil when the tail holds no
    /// timestamped record (a single record larger than the window) — the caller
    /// then has no evidence and keeps its previous behaviour.
    private static func lastTimestampInFile(_ url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 1 << 20
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        // Lossy on purpose: a conversation carries whatever its tools printed,
        // and one invalid byte inside a tool result would otherwise make the
        // whole read nil — which reads as "no evidence" and silently drops the
        // guard exactly when the history is messy.
        return SyncImport.lastRecordTimestamp(in: String(decoding: data, as: UTF8.self))
    }

    /// True when the local JSONL has grown past the offset we last pushed to
    /// the cloud — i.e. this Mac has conversation changes that the remote
    /// file cannot contain. Used to detect a two-sided edit (sync conflict).
    static func hasUnsyncedLocalChanges(agentType: String, cbcID: String, projectDir: String) -> Bool {
        guard let url = localJSONLURL(agentType: agentType, cbcID: cbcID, projectDir: projectDir),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        let offset = exportedOffset(for: cbcID)
        // A tracked offset ahead of the file cannot describe it (the file was
        // rewritten shorter, or the offset belongs to another machine's copy).
        // The old check (`size > offset`) read that as "the remote already has
        // everything" and imported with `overwrite` WITHOUT asking — a silent
        // overwrite of a conversation this Mac cannot prove it ever sent. Ask
        // instead: the prompt is cheap, the history is not.
        return Int64(size) != offset
    }

    /// What an import landed, in the coordinates of the file written here.
    ///
    /// Both numbers come from the backend rather than from the bundle: path
    /// mappings and cwd localization rewrite every record on the way in, so the
    /// file that lands is neither the same length nor necessarily the same
    /// conversation the cloud file described.
    struct ImportedConversation: Equatable {
        /// The written file's byte length. Export tracking starts here — the
        /// old code used the bundle's content length and left every import
        /// looking like an unsynced local change.
        let byteCount: Int64
        /// The compaction base the written file starts its live history at. 0 in
        /// the usual case, since a bundle's content already begins at its own
        /// boundary.
        let base: Int64
    }

    /// Scan the sync directory and import any remote file that is newer than
    /// the last one processed. `importBundle` performs the actual backend
    /// import (mode is "overwrite", or "new" when the user chooses to keep
    /// both versions) and reports where it landed (or throws).
    /// `onConflict` is consulted when both sides changed the same
    /// conversation; returning nil lets the caller skip that file entirely.
    /// Returns the list of imported cbc ids.
    static func importIfChanged(
        importBundle: (SessionExportBundle, String) async throws -> ImportedConversation,
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

            // An older copy in the cloud is not an update. The file's date says
            // only when it was written: an export from a machine whose own copy
            // is behind rewrites it with LESS history than this Mac has (two
            // machines whose copies had drifted apart did exactly that, and the
            // file arrived looking brand new). Overwriting would delete the
            // records in between, so the conversation's own records decide.
            // Skipped rather than replaced: this Mac has the newer copy, and
            // the export pass publishes it.
            if cloudIsBehindLocal(agentType: bundle.agentType, cbcID: cbcID,
                                  projectDir: bundle.projectDir, incoming: bundle.content) {
                lastImportedFileMtime[cbcID] = mtime.timeIntervalSince1970
                continue
            }

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
                let landed = try await importBundle(bundle, mode)
                // After an overwrite this Mac holds exactly what the cloud file
                // holds, so export tracking starts at its end. Left alone, the
                // offset keeps whatever it had before — often the value that
                // made the copy look unsynced, which would ask about a conflict
                // the user has just resolved. "new" creates a different
                // conversation, which has its own tracking.
                if mode != "new" {
                    recordExportedOffset(landed.byteCount, for: cbcID)
                    recordSyncBase(landed.base, for: cbcID)
                }
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
        defaults.removeObject(forKey: basesKey)
        defaults.removeObject(forKey: importedMtimesKey)
    }
}
