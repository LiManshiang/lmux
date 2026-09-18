import XCTest
@testable import LMUXCore

/// Covers the payload compression that keeps `.lmuxsession` files from growing
/// to the size of the conversation they carry. The failure that matters here is
/// a *misread* — compression that silently corrupts a conversation is worse
/// than no compression at all — so most of these assert refusals, not savings.
final class SyncPayloadCompressionTests: XCTestCase {

    /// A payload shaped like a real conversation: repetitive JSON records with
    /// the per-record `providerData` copy that dominates the real thing.
    private func conversationJSONL(records: Int, outputBytes: Int) -> String {
        let output = String(repeating: "x", count: outputBytes)
        return (0..<records).map { i in
            """
            {"type":"function_call_result","id":"rec\(i)","parentId":"rec\(i - 1)","output":{"type":"text","text":"\(output)"},\
            "providerData":{"agent":"cli","toolResult":{"content":"\(output)"},"model":"deepseek-v4-flash"}}
            """
        }.joined(separator: "\n")
    }

    // MARK: - Round trip

    func testLargePayloadRoundTrips() {
        let original = conversationJSONL(records: 40, outputBytes: 40_000)
        XCTAssertGreaterThan(original.utf8.count, SyncPayloadCompression.minimumBytes)

        let encoded = SyncPayloadCompression.encode(original)
        XCTAssertEqual(encoded.encoding, SyncPayloadCompression.lzfseBase64)
        XCTAssertNotEqual(encoded.content, original)

        let decoded = SyncPayloadCompression.decode(
            content: encoded.content,
            encoding: encoded.encoding)
        XCTAssertEqual(decoded, original)
    }

    func testLargePayloadGetsSmaller() {
        let original = conversationJSONL(records: 40, outputBytes: 40_000)
        let encoded = SyncPayloadCompression.encode(original)
        let ratio = Double(original.utf8.count) / Double(encoded.content.utf8.count)
        // The real conversation compresses 6.0x; this asserts the machinery is
        // engaged at all, not the exact ratio.
        XCTAssertGreaterThan(ratio, 2.0)
    }

    func testUnicodeSurvivesRoundTrip() {
        let original = String(repeating: "中文会话 · émoji 🚀 reasoning\n", count: 60_000)
        XCTAssertGreaterThan(original.utf8.count, SyncPayloadCompression.minimumBytes)

        let encoded = SyncPayloadCompression.encode(original)
        XCTAssertEqual(encoded.encoding, SyncPayloadCompression.lzfseBase64)
        XCTAssertEqual(
            SyncPayloadCompression.decode(content: encoded.content, encoding: encoded.encoding),
            original)
    }

    // MARK: - Small payloads stay plain

    func testSmallPayloadIsStoredPlain() {
        let original = "{\"type\":\"message\",\"content\":\"hi\"}"
        let encoded = SyncPayloadCompression.encode(original)
        XCTAssertNil(encoded.encoding)
        XCTAssertEqual(encoded.content, original)
        XCTAssertEqual(
            SyncPayloadCompression.decode(content: encoded.content, encoding: encoded.encoding),
            original)
    }

    func testEmptyPayloadIsStoredPlain() {
        let encoded = SyncPayloadCompression.encode("")
        XCTAssertNil(encoded.encoding)
        XCTAssertEqual(encoded.content, "")
    }

    /// Just under the line: still plain, so an older build on the other machine
    /// keeps reading it.
    func testPayloadJustUnderThresholdIsStoredPlain() {
        let original = String(repeating: "a", count: SyncPayloadCompression.minimumBytes - 1)
        XCTAssertNil(SyncPayloadCompression.encode(original).encoding)
    }

    // MARK: - Backward compatibility

    func testPayloadWithoutEncodingReadsAsPlainText() {
        let text = "{\"type\":\"message\"}"
        XCTAssertEqual(
            SyncPayloadCompression.decode(content: text, encoding: nil), text)
        XCTAssertEqual(
            SyncPayloadCompression.decode(content: text, encoding: ""), text)
    }

    // MARK: - Refusals

    /// A tag from a future build must not be read as text — that would import
    /// base64 (or whatever comes next) as if it were the conversation.
    func testUnknownEncodingIsRefused() {
        XCTAssertNil(SyncPayloadCompression.decode(content: "whatever", encoding: "zstd-base64"))
    }

    func testDamagedBase64IsRefused() {
        XCTAssertNil(SyncPayloadCompression.decode(
            content: "not base64 !!!", encoding: SyncPayloadCompression.lzfseBase64))
    }

    /// Valid base64 that was never LZFSE — e.g. a payload that got truncated or
    /// re-encoded in transit.
    func testBase64OfNonLZFSEDataIsRefused() {
        let junk = Data(repeating: 0x7f, count: 4096).base64EncodedString()
        XCTAssertNil(SyncPayloadCompression.decode(
            content: junk, encoding: SyncPayloadCompression.lzfseBase64))
    }

    func testLZFSEDataThatIsNotUTF8IsRefused() {
        // Compress bytes that are not valid UTF-8: the tag says the payload is
        // text, so it must fail rather than fabricate a string.
        let bytes = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        guard let packed = try? (bytes as NSData).compressed(using: .lzfse) else {
            return XCTFail("lzfse unavailable")
        }
        XCTAssertNil(SyncPayloadCompression.decode(
            content: (packed as Data).base64EncodedString(),
            encoding: SyncPayloadCompression.lzfseBase64))
    }
}
