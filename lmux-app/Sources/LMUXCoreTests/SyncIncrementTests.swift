import XCTest
@testable import LMUXCore

final class SyncIncrementTests: XCTestCase {
    // MARK: - First sync (no local file)

    func testFirstSyncNoLocalFile() {
        // No local copy, no prior offset → full conversation already fetched.
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: false, localOffset: 0, newOffset: 100, localFileOffsetMatches: false),
            .freshExport
        )
    }

    func testFirstSyncWithLocalOffsetZeroAndFile() {
        // File exists but offsets unknown (both zero) → nothing to append.
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: true, localOffset: 0, newOffset: 0, localFileOffsetMatches: true),
            .unchanged
        )
    }

    // MARK: - Deleted local copy

    func testLocalFileDeletedNeedsFullExport() {
        // We synchronized to 100 before, but the file is gone → rebuild.
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: false, localOffset: 100, newOffset: 100, localFileOffsetMatches: false),
            .needsFullExport
        )
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: false, localOffset: 100, newOffset: 120, localFileOffsetMatches: false),
            .needsFullExport
        )
    }

    // MARK: - Unchanged

    func testNoNewDataUnchanged() {
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: true, localOffset: 100, newOffset: 100, localFileOffsetMatches: true),
            .unchanged
        )
    }

    // MARK: - The source is behind the copy

    func testSourceBehindTheCopyNeedsFullExport() {
        // Not "nothing new": a conversation never shrinks, so a source shorter
        // than what we synchronized to is a different file — rewritten shorter
        // (a path repair rewrites the whole conversation) or covered by an
        // offset inherited from another machine's copy of it. Appending is
        // impossible; the copy has to be rebuilt.
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: true, localOffset: 100, newOffset: 50, localFileOffsetMatches: true),
            .needsFullExport
        )

        // An increment cannot fix it (there is no prefix to append to)…
        XCTAssertEqual(
            SyncIncrement.mirrorRepairDecision(
                hasLocalFile: true, localContentBytes: 100, effectiveOffset: 100,
                incomingBytes: 0, newOffset: 50),
            .needsFullExport
        )
        // …a full export can: it replaces the copy and the offset with it.
        XCTAssertEqual(
            SyncIncrement.mirrorRepairDecision(
                hasLocalFile: true, localContentBytes: 100, effectiveOffset: 100,
                incomingBytes: 50, newOffset: 50),
            .replaceFull
        )
        // The copy looking internally consistent (content == its offset) must
        // not excuse it: a mirror written on the other machine looks consistent
        // while describing a file this machine does not have.
        XCTAssertEqual(
            SyncIncrement.mirrorRepairDecision(
                hasLocalFile: true, localContentBytes: 83_287_742, effectiveOffset: 83_287_742,
                incomingBytes: 83_072_193, newOffset: 83_072_193),
            .replaceFull
        )
    }

    func testNewOffsetZeroWithExistingFile() {
        // No content (empty conversation) → unchanged.
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: true, localOffset: 0, newOffset: 0, localFileOffsetMatches: true),
            .unchanged
        )
    }

    // MARK: - Append increment

    func testNewDataAppends() {
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: true, localOffset: 100, newOffset: 150, localFileOffsetMatches: true),
            .append
        )
    }

    // MARK: - Inconsistent local copy

    func testLocalCopyOffsetMismatchNeedsFullExport() {
        // Local file exists but its recorded offset differs from our tracked
        // one (ahead/behind) → resync from zero.
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: true, localOffset: 100, newOffset: 150, localFileOffsetMatches: false),
            .needsFullExport
        )
    }

    // MARK: - effectiveOffset (lost tracked offset recovery)

    func testEffectiveOffsetKeepsValidTracking() {
        // File behind our tracked offset → tracking wins.
        XCTAssertEqual(SyncIncrement.effectiveOffset(localOffset: 150, fileOffset: 100), 150)
        // File offset equal → unchanged.
        XCTAssertEqual(SyncIncrement.effectiveOffset(localOffset: 150, fileOffset: 150), 150)
        // No file → tracking stays.
        XCTAssertEqual(SyncIncrement.effectiveOffset(localOffset: 150, fileOffset: nil), 150)
    }

    func testEffectiveOffsetRecoversLostTrackingFromFile() {
        // Tracking was reset to 0 (defaults migration) but the mirror file is
        // intact at 67852855 → converge on the file so append resumes.
        XCTAssertEqual(SyncIncrement.effectiveOffset(localOffset: 0, fileOffset: 67_852_855), 67_852_855)
        // Converged offset lets decide() take the append path (self-heals).
        let recovered = SyncIncrement.effectiveOffset(localOffset: 0, fileOffset: 67_852_855)
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: true, localOffset: recovered, newOffset: 67_910_211, localFileOffsetMatches: true),
            .append
        )
    }

    // MARK: - isFullExport (full-export bundles must not be appended)

    func testIsFullExport() {
        // Full export: content bytes == offset (whole JSONL).
        XCTAssertTrue(SyncIncrement.isFullExport(contentBytes: 67_910_211, offset: 67_910_211))
        // A full export from a slightly-grown JSONL is >= its offset.
        XCTAssertTrue(SyncIncrement.isFullExport(contentBytes: 68_298_139, offset: 68_298_139))
        // Incremental bundle: only the appended tail → far shorter than offset.
        XCTAssertFalse(SyncIncrement.isFullExport(contentBytes: 457_284, offset: 68_298_139))
        // Degenerate zero-offset bundle is not a full export.
        XCTAssertFalse(SyncIncrement.isFullExport(contentBytes: 0, offset: 0))
    }

    // MARK: - mirrorRepairDecision (corrupt mirror integrity guard)

    func testMirrorRepairProceedWhenContentMatchesOffset() {
        // Healthy copy: content length equals the trusted offset → normal flow.
        XCTAssertEqual(
            SyncIncrement.mirrorRepairDecision(
                hasLocalFile: true, localContentBytes: 67_852_855,
                effectiveOffset: 67_852_855, incomingBytes: 57_284, newOffset: 67_910_139),
            .proceed
        )
        // No local file → nothing to corrupt, normal flow.
        XCTAssertEqual(
            SyncIncrement.mirrorRepairDecision(
                hasLocalFile: false, localContentBytes: 0,
                effectiveOffset: 0, incomingBytes: 68_298_139, newOffset: 68_298_139),
            .proceed
        )
    }

    func testMirrorRepairReplaceFullWhenFullExportArrives() {
        // The field-reported corruption: local content doubled
        // (136_150_994 = 67_852_855 + full 68_298_139) while its offset still
        // claims 68_298_139. A full export (incoming == newOffset) replaces
        // the copy wholesale instead of appending onto the duplicate.
        XCTAssertEqual(
            SyncIncrement.mirrorRepairDecision(
                hasLocalFile: true, localContentBytes: 136_150_994,
                effectiveOffset: 68_298_139, incomingBytes: 68_298_139, newOffset: 68_298_139),
            .replaceFull
        )
    }

    func testMirrorRepairNeedsFullExportWhenOnlyIncrementArrives() {
        // Corrupt copy + increment-sized bundle → must re-export from zero
        // first; appending would duplicate the overlapped bytes again.
        XCTAssertEqual(
            SyncIncrement.mirrorRepairDecision(
                hasLocalFile: true, localContentBytes: 136_150_994,
                effectiveOffset: 68_298_139, incomingBytes: 57_284, newOffset: 68_298_139),
            .needsFullExport
        )
        // Degenerate: empty source with a corrupt copy → full re-export.
        XCTAssertEqual(
            SyncIncrement.mirrorRepairDecision(
                hasLocalFile: true, localContentBytes: 100,
                effectiveOffset: 50, incomingBytes: 0, newOffset: 0),
            .needsFullExport
        )
    }
}
