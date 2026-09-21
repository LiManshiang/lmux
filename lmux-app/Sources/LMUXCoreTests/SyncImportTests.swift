import XCTest
@testable import LMUXCore

final class SyncImportTests: XCTestCase {
    func testLastRecordTimestampTakesTheNewest() {
        let text = """
        {"id":"a","type":"message","timestamp":1000}
        {"id":"b","type":"message","timestamp":2000}
        """
        XCTAssertEqual(SyncImport.lastRecordTimestamp(in: text), 2000)
    }

    func testLastRecordTimestampSkipsRecordsWithoutOne() {
        // The newest record is bookkeeping: the answer is the newest record
        // that does carry a time, not "no answer".
        let text = """
        {"id":"a","type":"message","timestamp":1000}
        {"id":"b","type":"turn-metrics"}
        {"id":"c","type":"file-history-snapshot"}
        """
        XCTAssertEqual(SyncImport.lastRecordTimestamp(in: text), 1000)
    }

    func testLastRecordTimestampWithoutAnyTimestamp() {
        XCTAssertNil(SyncImport.lastRecordTimestamp(in: #"{"id":"a","type":"message"}"#))
        XCTAssertNil(SyncImport.lastRecordTimestamp(in: "not json at all"))
        XCTAssertNil(SyncImport.lastRecordTimestamp(in: ""))
    }

    func testLastRecordTimestampIgnoresATimestampThatIsNotANumber() {
        // A partial line from a bounded tail read must not be mistaken for a
        // record: the digits have to follow the key.
        XCTAssertNil(SyncImport.lastRecordTimestamp(in: #"{"timestamp":"nope"}"#))
    }

    func testCloudIsBehindLocal() {
        // The cloud copy stops earlier — an older copy, not an update.
        XCTAssertTrue(SyncImport.cloudIsBehindLocal(localLast: 2000, cloudLast: 1000))
        // Same point in the conversation: nothing to bring over.
        XCTAssertFalse(SyncImport.cloudIsBehindLocal(localLast: 2000, cloudLast: 2000))
        // The cloud copy is ahead: the normal import.
        XCTAssertFalse(SyncImport.cloudIsBehindLocal(localLast: 2000, cloudLast: 3000))
        // No evidence either way: never claim the cloud is behind.
        XCTAssertFalse(SyncImport.cloudIsBehindLocal(localLast: nil, cloudLast: 1000))
        XCTAssertFalse(SyncImport.cloudIsBehindLocal(localLast: 1000, cloudLast: nil))
    }

    func testCloudIsAheadOfLocal() {
        // History the other machine has and this one does not: publishing this
        // one's copy over it would delete that history.
        XCTAssertTrue(SyncImport.cloudIsAheadOfLocal(localLast: 1000, cloudLast: 2000))
        XCTAssertFalse(SyncImport.cloudIsAheadOfLocal(localLast: 2000, cloudLast: 2000))
        XCTAssertFalse(SyncImport.cloudIsAheadOfLocal(localLast: 2000, cloudLast: 1000))
        XCTAssertFalse(SyncImport.cloudIsAheadOfLocal(localLast: nil, cloudLast: 2000))
        XCTAssertFalse(SyncImport.cloudIsAheadOfLocal(localLast: 2000, cloudLast: nil))
    }
}
