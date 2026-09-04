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

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var syncDir: String? {
        get { UserDefaults.standard.string(forKey: syncDirKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncDirKey) }
    }

    static var pathMappings: [PathMapping] {
        get {
            guard let raw = UserDefaults.standard.array(forKey: mappingsKey) as? [[String]] else { return [] }
            return raw.compactMap { pair in
                guard pair.count == 2, !pair[0].isEmpty else { return nil }
                return PathMapping(from: pair[0], to: pair[1])
            }
        }
        set {
            let raw = newValue.map { [$0.from, $0.to] }
            UserDefaults.standard.set(raw, forKey: mappingsKey)
        }
    }

    static var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceIDKey)
        return id
    }

    // MARK: - Incremental sync state

    /// cbc_session_id -> byte offset up to which we have synchronized.
    /// Persisted so an incremental export resumes correctly after restart.
    private static var exportedOffsets: [String: Int64] {
        get {
            UserDefaults.standard.dictionary(forKey: offsetsKey) as? [String: Int64] ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: offsetsKey)
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
            UserDefaults.standard.dictionary(forKey: importedMtimesKey) as? [String: TimeInterval] ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: importedMtimesKey)
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

    /// Scan the sync directory and import any remote file that is newer than
    /// the last one processed. `importBundle` performs the actual backend
    /// import and returns the imported session's id (or throws).
    /// Returns the list of imported cbc ids.
    static func importIfChanged(
        importBundle: (SessionExportBundle) async throws -> Void
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

            do {
                try await importBundle(bundle)
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
        UserDefaults.standard.removeObject(forKey: offsetsKey)
        UserDefaults.standard.removeObject(forKey: importedMtimesKey)
    }
}
