import XCTest
@testable import LMUXCore

/// Mock AgentSessionService for testing resolveSession logic.
struct MockAgentService: AgentSessionService {
    var findResults: [AgentType: String?] = [:]
    var validResults: [String: Bool] = [:]
    var contextResults: [String: (tokens: Int, contextWindow: Int, credit: Double)] = [:]

    func findAgentSession(agent: AgentType, projectDir: String) async -> String? {
        findResults[agent] ?? nil
    }

    func agentSessionValid(agent: AgentType, sessionID: String) async -> Bool {
        validResults[sessionID] ?? false
    }

    func agentContext(agent: AgentType, projectDir: String, sessionID: String) async -> (tokens: Int, contextWindow: Int, credit: Double)? {
        contextResults[sessionID]
    }
}

final class CodebuddyProviderTests: XCTestCase {
    func testResumesWhenCBCIsValid() async {
        let svc = MockAgentService(validResults: ["cbc-1": true])
        let decision = await CodebuddyProvider().resolveSession(
            cbcSessionID: "cbc-1", projectDir: "/p", allowHistoryLookup: false, service: svc)
        guard case .resume(let id) = decision else {
            return XCTFail("expected resume, got \(decision)")
        }
        XCTAssertEqual(id, "cbc-1")
    }

    func testLooksUpHistoryWhenCBCInvalid() async {
        let svc = MockAgentService(
            findResults: [.codebuddy: "found-1"],
            validResults: ["cbc-1": false])
        let decision = await CodebuddyProvider().resolveSession(
            cbcSessionID: "cbc-1", projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .resume(let id) = decision else {
            return XCTFail("expected resume, got \(decision)")
        }
        XCTAssertEqual(id, "found-1")
    }

    func testFallsBackToBashWhenNothingFound() async {
        let svc = MockAgentService()
        let decision = await CodebuddyProvider().resolveSession(
            cbcSessionID: nil, projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .bash = decision else {
            return XCTFail("expected bash, got \(decision)")
        }
    }

    func testNoHistoryLookupForNewSession() async {
        let svc = MockAgentService(findResults: [.codebuddy: "found-1"])
        // allowHistoryLookup=false (fresh bash session): must not pick up history.
        let decision = await CodebuddyProvider().resolveSession(
            cbcSessionID: nil, projectDir: "/p", allowHistoryLookup: false, service: svc)
        guard case .bash = decision else {
            return XCTFail("expected bash (no history lookup), got \(decision)")
        }
    }
}

final class ClaudeProviderTests: XCTestCase {
    func testResumesClaudeCBC() async {
        // cbc is not a codebuddy conversation -> kept and resumed.
        let svc = MockAgentService(validResults: ["claude-1": false])
        let decision = await ClaudeProvider().resolveSession(
            cbcSessionID: "claude-1", projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .resume(let id) = decision else {
            return XCTFail("expected resume, got \(decision)")
        }
        XCTAssertEqual(id, "claude-1")
    }

    func testDiscardsCodebuddyCBC() async {
        // cbc is a valid codebuddy conversation -> must not be passed to claude.
        let svc = MockAgentService(
            findResults: [.claude: "claude-found"],
            validResults: ["cbc-1": true])
        let decision = await ClaudeProvider().resolveSession(
            cbcSessionID: "cbc-1", projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .resume(let id) = decision else {
            return XCTFail("expected resume, got \(decision)")
        }
        XCTAssertEqual(id, "claude-found")
    }

    func testFreshWhenNoHistory() async {
        let svc = MockAgentService()
        let decision = await ClaudeProvider().resolveSession(
            cbcSessionID: nil, projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .fresh = decision else {
            return XCTFail("expected fresh, got \(decision)")
        }
    }

    func testBashWhenNotAgentSession() async {
        let svc = MockAgentService()
        // A plain bash session (no history lookup) should stay bash, not fresh.
        let decision = await ClaudeProvider().resolveSession(
            cbcSessionID: nil, projectDir: "/p", allowHistoryLookup: false, service: svc)
        guard case .bash = decision else {
            return XCTFail("expected bash, got \(decision)")
        }
    }

    // MARK: - detectionSessionID (fresh agent launch must not leak into
    // another session's conversation on restart)

    func testDetectionUsesExplicitResumeIDWithoutHistoryLookup() async {
        let svc = MockAgentService(findResults: [.claude: "other-session"])
        // A --resume ID on the command line is authoritative even though
        // find-session would return another session's conversation.
        let id = await ClaudeProvider().detectionSessionID(
            cmdLineSessionID: "my-own", allowHistoryLookup: true,
            projectDir: "/p", service: svc)
        XCTAssertEqual(id, "my-own")
    }

    func testDetectionFallsBackToProjectHistoryForFreshLaunch() async {
        let svc = MockAgentService(findResults: [.claude: "recent-convo"])
        // claude freshly launched (no --resume): the project's most recent
        // conversation is associated so restart resumes the right one.
        let id = await ClaudeProvider().detectionSessionID(
            cmdLineSessionID: nil, allowHistoryLookup: true,
            projectDir: "/p", service: svc)
        XCTAssertEqual(id, "recent-convo")
    }

    func testDetectionSkipsHistoryForNewSession() async {
        let svc = MockAgentService(findResults: [.claude: "other-session"])
        // Brand-new session (no history lookup): must not pick up any existing
        // conversation — this is what prevents "switching to another session".
        let id = await ClaudeProvider().detectionSessionID(
            cmdLineSessionID: nil, allowHistoryLookup: false,
            projectDir: "/p", service: svc)
        XCTAssertNil(id)
    }
}

final class AgentBinaryLocatorTests: XCTestCase {
    func testExtractSessionID() {
        XCTAssertEqual(
            CodebuddyProvider().extractSessionID(from: "codebuddy-code --resume abc-123"),
            "abc-123")
        XCTAssertEqual(
            ClaudeProvider().extractSessionID(from: "claude --dangerously-skip-permissions --session-id=xyz-9"),
            "xyz-9")
        XCTAssertNil(CodebuddyProvider().extractSessionID(from: "codebuddy-code --permission-mode auto"))
    }

    func testDetectProcessMatches() {
        XCTAssertNotNil(CodebuddyProvider().detectProcess(cmdLine: "node codebuddy-code --resume abc"))
        XCTAssertNil(CodebuddyProvider().detectProcess(cmdLine: "claude --dangerously-skip-permissions"))
        XCTAssertNotNil(ClaudeProvider().detectProcess(cmdLine: "claude --dangerously-skip-permissions"))
        XCTAssertNil(ClaudeProvider().detectProcess(cmdLine: "node codebuddy-code"))
    }

    func testDetectProcessReportsMatchWithoutID() {
        // A claude started fresh (no --resume) must still be detected as claude.
        let match = ClaudeProvider().detectProcess(cmdLine: "claude --dangerously-skip-permissions")
        XCTAssertNotNil(match, "fresh claude should still match")
        XCTAssertNil(match?.sessionID)
    }
}
