import XCTest
@testable import LMUXCore

final class RelativeTimeTests: XCTestCase {
    /// A timestamp `seconds` in the past.
    private func ago(_ seconds: Int) -> Int64 {
        Int64(Date().timeIntervalSince1970) - Int64(seconds)
    }

    func testCompactFormThresholds() {
        XCTAssertEqual(RelativeTime.short(ago(0)), "now")
        XCTAssertEqual(RelativeTime.short(ago(59)), "now")
        XCTAssertEqual(RelativeTime.short(ago(60)), "1m")
        XCTAssertEqual(RelativeTime.short(ago(3599)), "59m")
        XCTAssertEqual(RelativeTime.short(ago(3600)), "1h")
        XCTAssertEqual(RelativeTime.short(ago(86_399)), "23h")
        XCTAssertEqual(RelativeTime.short(ago(86_400)), "1d")
        XCTAssertEqual(RelativeTime.short(ago(86_400 * 5)), "5d")
    }

    func testSentenceFormThresholds() {
        XCTAssertEqual(RelativeTime.short(ago(0), sentence: true), "just now")
        XCTAssertEqual(RelativeTime.short(ago(59), sentence: true), "just now")
        XCTAssertEqual(RelativeTime.short(ago(60), sentence: true), "1m ago")
        XCTAssertEqual(RelativeTime.short(ago(3600), sentence: true), "1h ago")
        XCTAssertEqual(RelativeTime.short(ago(86_400 * 2), sentence: true), "2d ago")
    }

    /// The two forms must agree on the numbers; only the wording differs.
    func testBothFormsShareTheSameBuckets() {
        for seconds in [60, 90, 3599, 3600, 7200, 86_399, 86_400, 172_800] {
            let compact = RelativeTime.short(ago(seconds))
            let sentence = RelativeTime.short(ago(seconds), sentence: true)
            XCTAssertEqual(
                sentence.replacingOccurrences(of: " ago", with: ""),
                compact,
                "bucket mismatch at \(seconds)s: \(compact) vs \(sentence)"
            )
        }
    }

    /// Clock skew (or a file written a moment in the future) must not produce
    /// negative durations.
    func testFutureTimestampsClampToNow() {
        let future = Int64(Date().timeIntervalSince1970) + 500
        XCTAssertEqual(RelativeTime.short(future), "now")
        XCTAssertEqual(RelativeTime.short(future, sentence: true), "just now")
    }
}
