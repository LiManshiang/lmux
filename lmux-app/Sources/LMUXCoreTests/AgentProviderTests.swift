import XCTest
@testable import LMUXCore

/// Mock AgentSessionService for testing resolveSession logic.
final class MockAgentService: AgentSessionService {
    var findResults: [AgentType: String?] = [:]
    var validResults: [String: Bool] = [:]
    var contextResults: [String: (tokens: Int, contextWindow: Int, credit: Double)] = [:]
    /// Records the `after` argument of the last findAgentSession call.
    var lastFindAfter: Date?

    init(
        findResults: [AgentType: String?] = [:],
        validResults: [String: Bool] = [:],
        contextResults: [String: (tokens: Int, contextWindow: Int, credit: Double)] = [:]
    ) {
        self.findResults = findResults
        self.validResults = validResults
        self.contextResults = contextResults
    }

    func findAgentSession(agent: AgentType, projectDir: String, after: Date?) async -> String? {
        lastFindAfter = after
        return findResults[agent] ?? nil
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
        // The stored cbc is not a valid conversation for this agent. We must
        // NOT fall back to the project's most recent conversation (find-session
        // returns whatever is newest in the project — usually ANOTHER session's
        // conversation). Start a fresh agent conversation instead.
        let decision = await CodebuddyProvider().resolveSession(
            cbcSessionID: "cbc-1", projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .fresh = decision else {
            return XCTFail("expected fresh, got \(decision)")
        }
    }

    func testFallsBackToBashWhenNothingFound() async {
        let svc = MockAgentService()
        // allowHistoryLookup=false (brand-new session): plain shell.
        let decision = await CodebuddyProvider().resolveSession(
            cbcSessionID: nil, projectDir: "/p", allowHistoryLookup: false, service: svc)
        guard case .bash = decision else {
            return XCTFail("expected bash, got \(decision)")
        }
    }

    func testAgentSessionWithoutCBCStartsFresh() async {
        // Regression: a session already upgraded to agent mode (restore
        // entry launchMode == .agent) but without a resumable cbc must start
        // a fresh codebuddy conversation, NOT fall back to a plain shell.
        // (observed: restart after launching codebuddy dropped into bash)
        let svc = MockAgentService()
        let decision = await CodebuddyProvider().resolveSession(
            cbcSessionID: nil, projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .fresh = decision else {
            return XCTFail("expected fresh (agent session without cbc), got \(decision)")
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

    // MARK: - detectionSessionID (codebuddy: fresh launch must bind to its own
    // conversation so the session can resume on restart)

    func testCodebuddyDetectionUsesExplicitResumeID() async {
        let svc = MockAgentService(findResults: [.codebuddy: ""])
        // No live conversation found (nothing written since launch): fall back
        // to the --resume ID on the command line.
        let id = await CodebuddyProvider().detectionSessionID(
            cmdLineSessionID: "my-own", allowHistoryLookup: true,
            projectDir: "/p", notBefore: Date(), service: svc)
        XCTAssertEqual(id, "my-own")
    }

    func testCodebuddyDetectionPrefersCmdLineResumeOverFindSession() async {
        // An explicit `--resume <id>` on the command line is authoritative.
        // find-session guesses from file timestamps and, when several sessions
        // share a project directory, frequently returns ANOTHER session's
        // conversation — overriding the command line is what made a working
        // lmux session silently rebind to a fresh empty conversation. The
        // explicit resume must win.
        let svc = MockAgentService(findResults: [.codebuddy: "find-session-guess"])
        let id = await CodebuddyProvider().detectionSessionID(
            cmdLineSessionID: "explicit-resume", allowHistoryLookup: true,
            projectDir: "/p", notBefore: Date(), service: svc)
        XCTAssertEqual(id, "explicit-resume")
    }

    func testCodebuddyDetectionScopesToProcessStart() async {
        let svc = MockAgentService(findResults: [.codebuddy: "own-new-convo"])
        let start = Date()
        let id = await CodebuddyProvider().detectionSessionID(
            cmdLineSessionID: nil, allowHistoryLookup: true,
            projectDir: "/p", notBefore: start, service: svc)
        XCTAssertEqual(id, "own-new-convo")
        // The start time must be forwarded as the find-session filter so an
        // older conversation owned by another session can't be picked up.
        XCTAssertEqual(svc.lastFindAfter, start)
    }

    func testCodebuddyDetectionNoStartTimeDoesNotBind() async {
        // Regression: when the process start time cannot be resolved, detection
        // must NOT bind to the project's most recent conversation. That recent
        // conversation usually belongs to a DIFFERENT session — binding it
        // makes several sessions share one cbc and restoring any of them
        // resumes the wrong conversation. Return nil and let the next
        // detection pick up the agent's own --resume ID.
        let svc = MockAgentService(findResults: [.codebuddy: "recent-convo"])
        let id = await CodebuddyProvider().detectionSessionID(
            cmdLineSessionID: nil, allowHistoryLookup: true,
            projectDir: "/p", notBefore: nil, service: svc)
        XCTAssertNil(id)
    }

    func testCodebuddyDetectionSkipsHistoryForNewSession() async {
        let svc = MockAgentService(findResults: [.codebuddy: "other-session"])
        // Brand-new session (no history lookup): must not pick up any existing
        // conversation.
        let id = await CodebuddyProvider().detectionSessionID(
            cmdLineSessionID: nil, allowHistoryLookup: false,
            projectDir: "/p", service: svc)
        XCTAssertNil(id)
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
        let svc = MockAgentService(findResults: [.claude: ""])
        // No live conversation written since launch: fall back to the --resume
        // ID on the command line.
        let id = await ClaudeProvider().detectionSessionID(
            cmdLineSessionID: "my-own", allowHistoryLookup: true,
            projectDir: "/p", notBefore: Date(), service: svc)
        XCTAssertEqual(id, "my-own")
    }

    func testDetectionFallsBackToProjectHistoryForFreshLaunch() async {
        let svc = MockAgentService(findResults: [.claude: "recent-convo"])
        // claude freshly launched (no --resume) WITH a known start time: the
        // project's conversation created after launch is associated so restart
        // resumes the right one.
        let id = await ClaudeProvider().detectionSessionID(
            cmdLineSessionID: nil, allowHistoryLookup: true,
            projectDir: "/p", notBefore: Date(), service: svc)
        XCTAssertEqual(id, "recent-convo")
    }

    func testDetectionNoStartTimeDoesNotBind() async {
        // When the process start time cannot be resolved, detection must not
        // bind to the project's most recent conversation — that frequently
        // belongs to another session and would make several sessions share one
        // cbc (wrong restore). Return nil; the next detection picks up the
        // agent's own --resume ID.
        let svc = MockAgentService(findResults: [.claude: "recent-convo"])
        let id = await ClaudeProvider().detectionSessionID(
            cmdLineSessionID: nil, allowHistoryLookup: true,
            projectDir: "/p", notBefore: nil, service: svc)
        XCTAssertNil(id)
    }

    func testResolutionEmptyCBCDoesNotResumeOtherSession() async {
        // Regression: restoring a session whose cbcSessionID is empty must not
        // fall back to the project's most recent claude conversation — that
        // wrongly resumed another session's work (observed bug).
        let svc = MockAgentService(findResults: [.claude: "other-session-convo"])
        let decision = await ClaudeProvider().resolveSession(
            cbcSessionID: nil, projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .fresh = decision else {
            return XCTFail("expected fresh (no history), got \(decision)")
        }
    }

    func testResolutionDiscardedCodebuddyStillLooksUpClaudeHistory() async {
        // When the stored ID was a codebuddy conversation (wrongly associated
        // with claude), claude history is still consulted for a valid claude ID.
        let svc = MockAgentService(
            findResults: [.claude: "claude-valid"],
            validResults: ["codebuddy-id": true])
        let decision = await ClaudeProvider().resolveSession(
            cbcSessionID: "codebuddy-id", projectDir: "/p", allowHistoryLookup: true, service: svc)
        guard case .resume(let id) = decision else {
            return XCTFail("expected resume from claude history, got \(decision)")
        }
        XCTAssertEqual(id, "claude-valid")
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

    func testDetectionScopesHistoryToProcessStart() async {
        let svc = MockAgentService(findResults: [.claude: "own-new-convo"])
        let start = Date()
        let id = await ClaudeProvider().detectionSessionID(
            cmdLineSessionID: nil, allowHistoryLookup: true,
            projectDir: "/p", notBefore: start, service: svc)
        XCTAssertEqual(id, "own-new-convo")
        // The agent process start time is forwarded as the find-session
        // filter, so an older conversation owned by another session can't be
        // picked up.
        XCTAssertEqual(svc.lastFindAfter, start)
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
