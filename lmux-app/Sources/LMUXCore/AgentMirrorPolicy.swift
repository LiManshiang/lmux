import Foundation

/// Pure decision layer for the agent-JSONL mirror (SessionSync). All mirror
/// I/O lives in SessionSync; whether a file should be copied, appended,
/// skipped or flagged as a two-way conflict is decided here so the rules can
/// be unit tested without touching the filesystem.
public enum AgentMirrorFileAction: Equatable {
    /// No local file yet — push the whole file to the mirror.
    case copyToMirror
    /// Mirror already holds an older prefix of the local file; append the tail.
    case appendToMirror
    /// No local file yet, but the mirror has one — pull it whole.
    case copyToLocal
    /// Local is unchanged since its last pull and the mirror grew; append the
    /// remote tail.
    case appendToLocal
    /// Both sides grew since the last sync — keep local (surfaced for the
    /// user to resolve, never silently overwritten).
    case conflictKeepLocal
    /// Up to date, already pushed, or covered by another rule — do nothing.
    case skip
}

public enum AgentMirrorPolicy {
    // MARK: Export (local → mirror)

    public struct ExportInputs {
        public let localSize: Int64
        public let localMTime: Int64
        public let mirrorExists: Bool
        public let mirrorSize: Int64
        /// "size,mtime" fingerprint recorded when this file was last pushed.
        public let lastExportFingerprint: String?
        /// Local size recorded when this file was last pulled from the mirror.
        /// Guards the loop: a file that is exactly what we pulled back is
        /// never re-pushed (agent JSONL carries no device id).
        public let lastImportSize: Int64?

        public init(localSize: Int64, localMTime: Int64, mirrorExists: Bool,
                    mirrorSize: Int64, lastExportFingerprint: String?, lastImportSize: Int64?) {
            self.localSize = localSize
            self.localMTime = localMTime
            self.mirrorExists = mirrorExists
            self.mirrorSize = mirrorSize
            self.lastExportFingerprint = lastExportFingerprint
            self.lastImportSize = lastImportSize
        }
    }

    public static func exportAction(_ input: ExportInputs) -> AgentMirrorFileAction {
        // Loop guard: never re-push a file whose current size is exactly what
        // we just pulled back from the mirror (nothing new locally).
        if let lastImportSize = input.lastImportSize, input.localSize <= lastImportSize {
            return .skip
        }
        // Unchanged since the last export.
        if input.lastExportFingerprint == "\(input.localSize),\(Int(input.localMTime))" {
            return .skip
        }
        // Append-only growth: mirror is a strict prefix of local → push the tail.
        if input.mirrorExists, input.mirrorSize > 0, input.mirrorSize < input.localSize {
            return .appendToMirror
        }
        // Fresh copy (whole file) when no mirror exists or the mirror content
        // is not a strict prefix (different machine wrote it).
        return .copyToMirror
    }

    // MARK: Import (mirror → local)

    public struct ImportInputs {
        public let localExists: Bool
        public let localSize: Int64
        /// Local size recorded when this file was last pulled from the mirror.
        public let lastImportSize: Int64?
        public let remoteSize: Int64

        public init(localExists: Bool, localSize: Int64, lastImportSize: Int64?, remoteSize: Int64) {
            self.localExists = localExists
            self.localSize = localSize
            self.lastImportSize = lastImportSize
            self.remoteSize = remoteSize
        }
    }

    public static func importAction(_ input: ImportInputs) -> AgentMirrorFileAction {
        if !input.localExists {
            return .copyToLocal
        }
        if let lastImportSize = input.lastImportSize,
           input.localSize == lastImportSize,
           input.remoteSize > input.localSize {
            // Local unchanged since we last pulled; mirror advanced → append.
            return .appendToLocal
        }
        if input.remoteSize > input.localSize {
            // This machine kept writing AND the mirror also grew → two-way
            // change. Keep local (the export pass pushes our tail next run).
            return .conflictKeepLocal
        }
        // remoteSize <= localSize → local is newer/equal; export handles it.
        return .skip
    }
}

/// File-level helpers shared by the mirror. Kept here (instead of in the app
/// target) so the byte-level append/merge behaviour is unit testable.
public enum AgentMirrorIO {
    /// Copy the bytes of `source` from `fromOffset` to the end of `target`.
    /// Agent JSONL is append-only, so the tail is the new content.
    public static func appendTail(from source: URL, to target: URL, fromOffset: Int64) throws {
        let handle = try FileHandle(forWritingTo: target)
        try handle.seekToEnd()
        let reader = try FileHandle(forReadingFrom: source)
        try reader.seek(toOffset: UInt64(fromOffset))
        if let tail = try reader.readToEnd() {
            try handle.write(contentsOf: tail)
        }
        try handle.close()
        try reader.close()
    }
}
