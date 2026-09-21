import XCTest
@testable import LMUXCore

/// The export plan decides what a sync copy (`.lmuxsession`) does with an
/// incoming bundle. The defaults below describe a healthy, mid-life
/// conversation: the copy was written here at compaction base 60 and reaches
/// source offset 100 (40 bytes of content), and the bundle is an increment
/// continuing from there to 120.
final class SyncIncrementTests: XCTestCase {
    private func plan(
        hasMirror: Bool = true,
        owned: Bool = true,
        mirrorOffset: Int64 = 100,
        mirrorContentBytes: Int64 = 40,
        knownBase: Int64 = 60,
        tracked: Int64 = 100,
        incomingBase: Int64 = 60,
        incomingContentStart: Int64 = 100,
        incomingBytes: Int64 = 20,
        newOffset: Int64 = 120,
        incomingEqualsMirror: Bool = false
    ) -> SyncIncrement.ExportPlan {
        SyncIncrement.plan(
            hasMirror: hasMirror,
            mirrorOwnedByThisDevice: owned,
            mirrorOffset: mirrorOffset,
            mirrorContentBytes: mirrorContentBytes,
            knownBase: knownBase,
            trackedOffset: tracked,
            incomingBase: incomingBase,
            incomingContentStart: incomingContentStart,
            incomingBytes: incomingBytes,
            newOffset: newOffset,
            incomingEqualsMirror: incomingEqualsMirror
        )
    }

    // MARK: - Appending

    func testAppendsIncrementContinuingTheCopy() {
        // The bundle starts exactly where the copy ends: the common case.
        XCTAssertEqual(plan(), .append)
    }

    func testBaseZeroBehavesLikeAnUncompactedConversation() {
        // With no compaction the copy holds the whole file, so the old
        // invariant "content length == offset" still holds.
        XCTAssertEqual(
            plan(mirrorOffset: 100, mirrorContentBytes: 100, knownBase: 0,
                 tracked: 100, incomingBase: 0, incomingContentStart: 100),
            .append)
    }

    // MARK: - Never writing

    func testEmptyIncrementNeverWrites() {
        // An export past the end of the file, or an idle conversation. Writing
        // would erase the copy; not writing keeps the modification date intact.
        XCTAssertEqual(plan(incomingBytes: 0), .unchanged)
    }

    func testIdenticalContentDoesNotRewrite() {
        // Writing byte-identical content only moves the file's modification
        // date, which reads as "the remote changed" on the other machine. In a
        // loop that never settles.
        XCTAssertEqual(
            plan(owned: false, incomingContentStart: 60, incomingBytes: 60,
                 newOffset: 120, incomingEqualsMirror: true),
            .unchanged)
    }

    // MARK: - First sync and lost copies

    func testFirstSyncWritesBaseRelativeContent() {
        // No copy yet, and the caller asked from zero: the backend answers from
        // the compaction base, so the bundle can become the whole copy.
        XCTAssertEqual(
            plan(hasMirror: false, tracked: 0,
                 incomingContentStart: 60, incomingBytes: 60, newOffset: 120),
            .replace)
    }

    func testDeletedCopyNeedsFullExport() {
        // The copy was deleted here while our tracking survived, so the caller
        // asks from offset 100 — an increment that cannot stand in for
        // source[60:]. Rebuild from the base instead.
        XCTAssertEqual(
            plan(hasMirror: false, tracked: 100,
                 incomingContentStart: 100, incomingBytes: 20, newOffset: 120),
            .needsFullExport)
    }

    func testSourceRewrittenShorterNeedsFullExport() {
        // A cwd repair rewrites the whole conversation when the recorded
        // directory stops matching, and importing a trimmed copy replaces it
        // outright. Both can leave the source shorter than what we published.
        // Checked before the empty-increment rule: an increment past the new end
        // of the file arrives empty, and "nothing to write" would leave a copy
        // describing more conversation than the file holds.
        XCTAssertEqual(
            plan(tracked: 140, incomingContentStart: 140, incomingBytes: 0,
                 newOffset: 120),
            .needsFullExport)
    }

    // MARK: - The compaction base

    func testNewCompactionBoundaryRebuildsFromTheBase() {
        // A compaction landed at offset 90_000. Every byte the copy holds is now
        // the dead prefix the CLI has stopped reading, so an increment from our
        // old offset cannot extend it...
        XCTAssertEqual(
            plan(incomingBase: 90_000, incomingContentStart: 100,
                 incomingBytes: 20, newOffset: 90_500),
            .needsFullExport)

        // ...while a fresh export that reaches back to the new boundary
        // replaces the copy wholesale.
        XCTAssertEqual(
            plan(incomingBase: 90_000, incomingContentStart: 90_000,
                 incomingBytes: 500, newOffset: 90_500),
            .replace)
    }

    func testQuietCompactedConversationIsStillRebuilt() {
        // The conversation compacted and then went quiet, so the bundle carries
        // nothing. "Nothing to write" would keep the copy carrying the dead
        // prefix for as long as the session stays idle — which is the case this
        // whole feature exists to fix, so the base is checked first.
        XCTAssertEqual(
            plan(incomingBase: 90_000, incomingContentStart: 100, incomingBytes: 0,
                 newOffset: 100),
            .needsFullExport)
    }

    func testBoundaryMovingEarlierAlsoRebuilds() {
        // A copy imported from a machine that compacted at a different point can
        // leave the local boundary behind the one the copy was written at. The
        // ranges no longer line up, so the copy is rebuilt rather than extended.
        XCTAssertEqual(plan(incomingBase: 10), .needsFullExport)
        XCTAssertEqual(
            plan(incomingBase: 10, incomingContentStart: 10, incomingBytes: 500,
                 newOffset: 520),
            .replace)
    }

    // MARK: - Distrusting the copy

    func testForeignCopyIsReplacedNeverExtended() {
        // Another device's copy carries its own file's offsets. It can be
        // replaced by a base-relative export, but never appended to.
        XCTAssertEqual(plan(owned: false), .needsFullExport)
        XCTAssertEqual(
            plan(owned: false, incomingContentStart: 60, incomingBytes: 60,
                 newOffset: 120),
            .replace)
    }

    func testCorruptCopyIsReplaced() {
        // 80 content bytes against an offset 40 past the base: the shape a past
        // bug produced by stacking a full export onto an intact copy.
        XCTAssertEqual(plan(mirrorContentBytes: 80), .needsFullExport)
        XCTAssertEqual(
            plan(mirrorContentBytes: 80, incomingContentStart: 60,
                 incomingBytes: 60, newOffset: 120),
            .replace)
    }

    func testIncrementStartingBeforeTheCopyEndNeedsFullExport() {
        // The tracked offset ran ahead of the copy, so the increment begins
        // inside what the copy already holds. Appending would duplicate it.
        XCTAssertEqual(plan(incomingContentStart: 80), .needsFullExport)
    }

    // MARK: - Requested since offset

    func testRequestSinceUsesOurTrackingByDefault() {
        XCTAssertEqual(
            SyncIncrement.requestSinceOffset(tracked: 100, mirrorOffset: nil,
                                             mirrorOwnedByThisDevice: false),
            100)
    }

    func testRequestSinceRecoversFromOurOwnCopyAheadOfTracking() {
        // Defaults migration lost the tracked offset while the copy on disk is
        // intact and further along. Asking from zero would return bytes the copy
        // already holds, and appending them would duplicate the conversation.
        XCTAssertEqual(
            SyncIncrement.requestSinceOffset(tracked: 0, mirrorOffset: 67_852_855,
                                             mirrorOwnedByThisDevice: true),
            67_852_855)
    }

    func testRequestSinceIgnoresOurOwnCopyBehindTracking() {
        XCTAssertEqual(
            SyncIncrement.requestSinceOffset(tracked: 150, mirrorOffset: 100,
                                             mirrorOwnedByThisDevice: true),
            150)
    }

    func testRequestSinceIgnoresAnotherDevicesCopy() {
        // Its offset counts bytes of a different file; using it makes the
        // backend answer with a slice this machine's file does not share.
        XCTAssertEqual(
            SyncIncrement.requestSinceOffset(tracked: 40, mirrorOffset: 67_852_855,
                                             mirrorOwnedByThisDevice: false),
            40)
    }
}
