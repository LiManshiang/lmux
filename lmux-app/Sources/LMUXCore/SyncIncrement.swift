import Foundation

/// Pure decision logic for incremental session export, extracted so it can be
/// unit tested without touching the filesystem or UserDefaults.
///
/// A sync copy (`.lmuxsession`) holds `source[base : offset]`: the conversation
/// from its last compaction boundary to its end. /compact — and the automatic
/// compaction that runs when the context fills up — leaves everything before
/// that boundary in the file, but the CLI slices it out of every model request
/// (`HistoryUtils.filterBeforeCompactedMessage`), so a copy has no reason to
/// carry it. Measured on this machine, an 83 MB conversation keeps 18 MB from
/// its boundary on.
///
/// `base` is a byte offset into the source file, which makes it meaningful only
/// on the machine that computed it. That is why the base is remembered locally
/// rather than carried in the bundle, and why a copy another device wrote can
/// never be extended — only replaced.
public enum SyncIncrement {
    /// What to do with an export bundle.
    public enum ExportPlan: Equatable {
        /// The copy already holds exactly these bytes, or the bundle carries
        /// nothing: do not write. Rewriting would move the file's modification
        /// date, which reads as "the remote changed" on the other machine and
        /// drags it into a re-import it does not need.
        case unchanged
        /// Append the bundle's content to the copy's.
        case append
        /// Write the bundle's content as the whole copy.
        case replace
        /// The bundle is only an increment and cannot stand in for the whole
        /// `source[base:]` range. The caller re-exports from zero — the backend
        /// then answers from the compaction base — and decides again.
        case needsFullExport
    }

    /// Decide how to handle an export bundle.
    ///
    /// - Parameters:
    ///   - hasMirror: whether a `.lmuxsession` copy exists on disk.
    ///   - mirrorOwnedByThisDevice: whether that copy was written here. Another
    ///     device's copy carries its own file's offsets, which describe nothing
    ///     about this one.
    ///   - mirrorOffset: the source byte offset the copy claims to reach.
    ///   - mirrorContentBytes: the copy's actual content length.
    ///   - knownBase: the source offset the copy's content starts at (persisted
    ///     per conversation, updated whenever the copy is written).
    ///   - trackedOffset: how far this conversation has been published.
    ///   - incomingBase: the source's current compaction boundary, as reported
    ///     by the backend.
    ///   - incomingContentStart: where the bundle's content starts in the source.
    ///     Equal to `incomingBase` for a fresh base-relative export, and to the
    ///     requested offset for an increment.
    ///   - incomingBytes: the bundle's content length.
    ///   - newOffset: the source's total size, as reported by the backend.
    ///   - incomingEqualsMirror: whether the bundle's content is byte-identical
    ///     to the copy's.
    public static func plan(
        hasMirror: Bool,
        mirrorOwnedByThisDevice: Bool,
        mirrorOffset: Int64,
        mirrorContentBytes: Int64,
        knownBase: Int64,
        trackedOffset: Int64,
        incomingBase: Int64,
        incomingContentStart: Int64,
        incomingBytes: Int64,
        newOffset: Int64,
        incomingEqualsMirror: Bool
    ) -> ExportPlan {
        // A conversation only grows. A source that no longer reaches as far as
        // what we published was rewritten shorter — a cwd repair rewrites the
        // whole file when the recorded directory stops matching, and importing a
        // trimmed copy replaces it outright — so there is nothing to append to
        // and the copy has to be rebuilt from the base.
        if hasMirror, trackedOffset > newOffset {
            return .needsFullExport
        }

        // Content that reaches back to the base can stand in for the whole
        // `source[base:]` range. An increment that starts later cannot.
        let coversFromBase = incomingContentStart == incomingBase

        func rebuild() -> ExportPlan {
            guard coversFromBase else { return .needsFullExport }
            return incomingEqualsMirror ? .unchanged : .replace
        }

        // Every byte the copy holds was taken at `knownBase`. A conversation
        // that moved on to a later boundary leaves the copy holding exactly the
        // dead prefix this whole exercise exists to drop; a boundary that moved
        // *earlier* (a copy imported from a machine that compacted at a
        // different point) invalidates it just as thoroughly.
        //
        // Deliberately before the empty-increment rule below. A conversation
        // that compacted and then went quiet sends nothing new, and "nothing to
        // write" would keep the copy carrying the dead prefix for as long as the
        // session stays idle — which is exactly the case worth fixing.
        if hasMirror, incomingBase != knownBase { return rebuild() }

        // An empty increment is otherwise never a reason to write: when the copy
        // is not empty, writing it would erase the conversation.
        guard incomingBytes > 0 else { return .unchanged }

        if !hasMirror { return rebuild() }

        // Another device's copy cannot be extended, because appending to it
        // would build a conversation out of two machines' offsets.
        if !mirrorOwnedByThisDevice { return rebuild() }

        // The copy must really hold `source[knownBase:mirrorOffset]`. A copy
        // whose content length disagrees with its offset is what a past bug
        // produced — a full export stacked onto an intact copy, doubling the
        // conversation — and must never be appended to.
        if mirrorContentBytes != mirrorOffset - knownBase { return rebuild() }

        // The increment continues exactly where the copy ends.
        if incomingContentStart == mirrorOffset { return .append }

        // The increment starts somewhere else: the tracked offset ran ahead of
        // the copy, or the source was rewritten. Only a base-relative export can
        // replace the range the copy is supposed to cover.
        return rebuild()
    }

    /// The `since` offset to request for the next export.
    ///
    /// The persisted tracking can be lost or lag behind (defaults migration,
    /// resets) while the copy on disk is further along. The request must use the
    /// same basis as the plan below, or the backend returns bytes the copy
    /// already holds and appending them duplicates the conversation. So: the
    /// copy's offset when it is ours and ahead, otherwise our own tracking.
    ///
    /// A copy another device wrote is never a basis: its offset counts bytes of
    /// a different file.
    public static func requestSinceOffset(
        tracked: Int64,
        mirrorOffset: Int64?,
        mirrorOwnedByThisDevice: Bool
    ) -> Int64 {
        guard mirrorOwnedByThisDevice, let mirrorOffset, mirrorOffset > tracked else {
            return tracked
        }
        return mirrorOffset
    }
}
