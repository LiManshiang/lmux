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

    /// Recover a lost tracked offset from the local mirror file itself.
    ///
    /// The persisted per-conversation offset can be missing or reset (e.g.
    /// the sync state moved to a shared UserDefaults suite and the migration
    /// only copied part of it), while the mirror `.lmuxsession` on disk is
    /// intact and actually further along than our (zero) tracking. In that
    /// case `decide` would return `.needsFullExport` forever — every sync
    /// pass demands a full re-export, the full export is refused again for
    /// the same reason, and nothing is ever written. Converging on the
    /// file's offset lets the normal append path resume and self-heal.
    public static func effectiveOffset(localOffset: Int64, fileOffset: Int64?) -> Int64 {
        guard let fileOffset, fileOffset > localOffset else { return localOffset }
        return fileOffset
    }

    /// Whether an export bundle already carries the entire conversation.
    ///
    /// A bundle fetched WITHOUT a `since` offset is a full export: its
    /// `content` is the whole JSONL, so its UTF-8 byte length equals its
    /// `offset`. An incremental bundle is only the appended tail and is far
    /// shorter. Appending a full export to the mirror prefix would duplicate
    /// the whole conversation (mirror byte size ≈ prefix + full export), so
    /// the writer must overwrite instead of append when this is true.
    public static func isFullExport(contentBytes: Int64, offset: Int64) -> Bool {
        offset > 0 && contentBytes >= offset
    }

    // MARK: - Mirror integrity

    /// What to do when the local mirror's actual content size disagrees with
    /// the offset it claims (e.g. a historical bug appended a full export on
    /// top of an intact copy, doubling the conversation).
    public enum MirrorRepairDecision: Equatable {
        /// Content length matches the offset — run the normal decide flow.
        case proceed
        /// Corrupt copy, but the incoming bundle is a full export — replace
        /// the local content wholesale (self-heal).
        case replaceFull
        /// Corrupt copy and the incoming bundle is only an increment — the
        /// caller must re-export from zero first.
        case needsFullExport
    }

    /// Appending is only safe when the local copy's real byte length equals
    /// the offset the merge logic believes it has. A copy whose content
    /// outgrew its recorded offset would duplicate everything already in it.
    ///
    /// - Parameters:
    ///   - hasLocalFile: whether a mirror copy exists.
    ///   - localContentBytes: actual UTF-8 byte length of the local copy.
    ///   - effectiveOffset: the (possibly healed) offset the merge trusts.
    ///   - incomingBytes: UTF-8 byte length of the bundle being merged.
    ///   - newOffset: total source size the backend reports.
    public static func mirrorRepairDecision(
        hasLocalFile: Bool,
        localContentBytes: Int64,
        effectiveOffset: Int64,
        incomingBytes: Int64,
        newOffset: Int64
    ) -> MirrorRepairDecision {
        guard hasLocalFile, localContentBytes != effectiveOffset else { return .proceed }
        return (newOffset > 0 && incomingBytes == newOffset) ? .replaceFull : .needsFullExport
    }
}
