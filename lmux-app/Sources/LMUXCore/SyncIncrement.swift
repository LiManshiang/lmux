import Foundation

/// Pure decision logic for incremental session export, extracted so it can be
/// unit tested without touching the filesystem or UserDefaults.
///
/// The cross-device sync layer exports each pinned session's conversation
/// incrementally: the backend reports the JSONL's current size (`newOffset`),
/// and we only need to transfer the appended bytes. This enum decides what to
/// do with that information.
public enum SyncIncrement {
    public enum Decision: Equatable {
        /// Local copy exists and is current — nothing to write.
        case unchanged
        /// Local copy exists and is behind — merge the increment into it.
        case append
        /// Local copy is missing while we had synchronized before (deleted on
        /// this machine), or offsets are inconsistent — re-export everything.
        case needsFullExport
        /// First sync, no local copy, no prior offset — write the full
        /// conversation that the caller already fetched.
        case freshExport
    }

    /// Decide how to handle an incremental export.
    ///
    /// - Parameters:
    ///   - hasLocalFile: whether a matching `.lmuxsession` exists on disk.
    ///   - localOffset: byte offset we last synchronized to (persisted).
    ///   - newOffset: current JSONL size reported by the backend.
    ///   - localFileOffsetMatches: whether the local copy's own recorded offset
    ///     equals `localOffset` (i.e. we can safely append to it).
    public static func decide(
        hasLocalFile: Bool,
        localOffset: Int64,
        newOffset: Int64,
        localFileOffsetMatches: Bool
    ) -> Decision {
        guard hasLocalFile else {
            // No local copy. If we had synchronized before, the file was
            // deleted on this machine and the whole conversation must be
            // re-exported. Otherwise this is a true first sync.
            return localOffset > 0 ? .needsFullExport : .freshExport
        }

        // Nothing new to append.
        if newOffset <= localOffset {
            return .unchanged
        }

        // Local copy is consistent with our tracked offset — append increment.
        if localFileOffsetMatches {
            return .append
        }

        // Local copy is ahead/behind our tracked offset — resync from zero.
        return .needsFullExport
    }
}
