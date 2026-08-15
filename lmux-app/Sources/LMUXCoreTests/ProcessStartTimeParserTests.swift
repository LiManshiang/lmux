import XCTest
@testable import LMUXCore

final class ProcessStartTimeParserTests: XCTestCase {
    func testParsesEnglishDate() {
        let date = ProcessStartTimeParser.parse("Sat Aug 15 16:58:33 2026")
        XCTAssertNotNil(date)
        // DateFormatter parses in the system time zone; verify by re-formatting
        // the same way rather than assuming UTC.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        XCTAssertEqual(formatter.string(from: date!), "Sat Aug 15 16:58:33 2026")
    }

    func testParsesTrailingTabVariant() {
        let date = ProcessStartTimeParser.parse("Sat Aug 15 16:58:33 2026\t")
        XCTAssertNotNil(date, "trailing tab after the year must still parse")
    }

    func testParsesLeadingTrailingWhitespace() {
        let date = ProcessStartTimeParser.parse("  Sat Aug 15 16:58:33 2026  ")
        XCTAssertNotNil(date)
    }

    func testRejectsLocalizedDate() {
        // zh_CN ps output observed in the wild; the English formatter must not
        // half-parse it (this was the restore-breaking bug: notBefore became
        // nil, so no session ever bound a conversation).
        let date = ProcessStartTimeParser.parse("六  8月/15 16:58:33 2026")
        XCTAssertNil(date)
    }

    func testRejectsEmpty() {
        XCTAssertNil(ProcessStartTimeParser.parse(""))
        XCTAssertNil(ProcessStartTimeParser.parse("  "))
    }
}
