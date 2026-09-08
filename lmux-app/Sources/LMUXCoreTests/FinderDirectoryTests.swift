import XCTest
@testable import LMUXCore

final class FinderDirectoryTests: XCTestCase {
    // MARK: - agentCwd preferred (session's real working directory)

    func testAgentCwdPreferred() {
        // deep icon server case: DB projectDir is a stale creation-time path
        // (an iCloud sync dir) while the agent actually works elsewhere.
        XCTAssertEqual(
            FinderDirectory.resolve(
                projectDir: "/Users/x/Library/Mobile Documents/com~apple~CloudDocs/lmuxsessions",
                agentCwd: "/Volumes/Developer/Projects/deep_icon_server"),
            "/Volumes/Developer/Projects/deep_icon_server"
        )
    }

    // MARK: - projectDir fallback

    func testProjectDirFallbackWhenAgentCwdNil() {
        XCTAssertEqual(
            FinderDirectory.resolve(projectDir: "/Volumes/Dev/proj", agentCwd: nil),
            "/Volumes/Dev/proj"
        )
    }

    func testProjectDirFallbackWhenAgentCwdEmpty() {
        XCTAssertEqual(
            FinderDirectory.resolve(projectDir: "/Volumes/Dev/proj", agentCwd: ""),
            "/Volumes/Dev/proj"
        )
    }

    func testProjectDirFallbackWhenAgentCwdWhitespaceOnly() {
        XCTAssertEqual(
            FinderDirectory.resolve(projectDir: "/Volumes/Dev/proj", agentCwd: "   "),
            "/Volumes/Dev/proj"
        )
    }
}
