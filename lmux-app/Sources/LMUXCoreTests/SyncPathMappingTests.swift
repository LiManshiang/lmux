import XCTest
@testable import LMUXCore

final class SyncPathMappingTests: XCTestCase {
    func testApplyLongestPrefixFirst() {
        let mappings = [
            PathMapping(from: "/Users/limanshiang", to: "/Users/manshiangli"),
            PathMapping(from: "/Users/limanshiang/lmux-test-agent", to: "/Users/manshiangli/agent"),
        ]
        // Longest prefix wins regardless of array order.
        XCTAssertEqual(
            SyncPathMapping.apply("/Users/limanshiang/lmux-test-agent/src/main.go", mappings: mappings),
            "/Users/manshiangli/agent/src/main.go"
        )
        XCTAssertEqual(
            SyncPathMapping.apply("/Users/limanshiang/proj", mappings: mappings),
            "/Users/manshiangli/proj"
        )
    }

    func testApplyTextBlob() {
        let mappings = [
            PathMapping(from: "/Volumes/Developer/CodeBuddy", to: "/Users/manshiangli/cb"),
        ]
        let jsonl = #"{"sessionId":"a","cwd":"/Volumes/Developer/CodeBuddy/Proj"}"# + "\n" +
                    #"{"sessionId":"a","cwd":"/Volumes/Developer/CodeBuddy/Proj"}"#
        let out = SyncPathMapping.apply(jsonl, mappings: mappings)
        XCTAssertTrue(out.contains(#""cwd":"/Users/manshiangli/cb/Proj""#))
        XCTAssertFalse(out.contains("/Volumes/Developer/CodeBuddy"))
    }

    func testEmptyMappingsNoop() {
        XCTAssertEqual(SyncPathMapping.apply("/a/b/c", mappings: []), "/a/b/c")
    }

    func testMappingSortingIsStable() {
        // The same text with mappings in different order yields same output.
        let m1 = [
            PathMapping(from: "/a/b", to: "/x"),
            PathMapping(from: "/a/b/c", to: "/y"),
        ]
        let m2 = [
            PathMapping(from: "/a/b/c", to: "/y"),
            PathMapping(from: "/a/b", to: "/x"),
        ]
        XCTAssertEqual(
            SyncPathMapping.apply("/a/b/c/file", mappings: m1),
            SyncPathMapping.apply("/a/b/c/file", mappings: m2)
        )
    }

    func testSanitizeFileName() {
        XCTAssertEqual(SyncPathMapping.sanitizeFileName("重构/设置界面"), "重构-设置界面")
        XCTAssertEqual(SyncPathMapping.sanitizeFileName("a:b?c*d"), "a-b-c-d")
        XCTAssertEqual(SyncPathMapping.sanitizeFileName("  正常名字  "), "正常名字")
        XCTAssertEqual(SyncPathMapping.sanitizeFileName("///"), "")
    }
}
