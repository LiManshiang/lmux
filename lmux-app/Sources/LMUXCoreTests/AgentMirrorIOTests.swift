import XCTest
@testable import LMUXCore

final class AgentMirrorIOTests: XCTestCase {
    func testAppendTailMergesBytesAtOffset() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmux-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("target.jsonl")
        let source = dir.appendingPathComponent("source.jsonl")

        // target holds the first half, source holds the full content.
        let first = Data("line1\nline2\n".utf8)
        let full = Data("line1\nline2\nline3\nline4\n".utf8)
        try first.write(to: target)
        try full.write(to: source)

        // Merge: target should end up byte-identical to source.
        try AgentMirrorIO.appendTail(from: source, to: target, fromOffset: Int64(first.count))
        let merged = try Data(contentsOf: target)
        XCTAssertEqual(merged, full)

        // Appending again must be a no-op when there is nothing new left.
        try AgentMirrorIO.appendTail(from: source, to: target, fromOffset: Int64(full.count))
        XCTAssertEqual(try Data(contentsOf: target), full)
    }

    func testAppendTailOnNewerTargetDoesNotDuplicates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lmux-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("target.jsonl")
        let source = dir.appendingPathComponent("source.jsonl")
        // Local (target) grew past the mirror (source): appending the remaining
        // tail from an older source must not duplicate already-present bytes.
        try Data("a\nb\nc\n".utf8).write(to: source)
        try Data("a\nb\nc\nd\n".utf8).write(to: target)
        try AgentMirrorIO.appendTail(from: source, to: target, fromOffset: Int64(sourceSize(source)))
        let result = try String(contentsOf: target, encoding: .utf8)
        XCTAssertEqual(result, "a\nb\nc\nd\n")
    }

    private func sourceSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .intValue ?? 0
    }
}
