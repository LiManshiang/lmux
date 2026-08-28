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
        // Backend reports smaller (should not happen) → also unchanged.
        XCTAssertEqual(
            SyncIncrement.decide(hasLocalFile: true, localOffset: 100, newOffset: 50, localFileOffsetMatches: true),
            .unchanged
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
}
