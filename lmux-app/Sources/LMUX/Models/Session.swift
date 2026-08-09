import Foundation

enum AgentType: String, Codable, CaseIterable {
    case codebuddy
    case claude

    var displayName: String {
        switch self {
        case .codebuddy: return "CodeBuddy"
        case .claude: return "Claude Code"
        }
    }

    var executableName: String {
        switch self {
        case .codebuddy: return "codebuddy-code"
        case .claude: return "claude"
        }
    }

    var launchArgs: [String] {
        switch self {
        case .codebuddy: return ["--permission-mode", "auto", "-y"]
        case .claude: return ["--dangerously-skip-permissions"]
        }
    }

    /// Arguments that resume an existing conversation by session ID.
    /// Both codebuddy-code (-r/--resume) and claude (--resume) use `--resume <id>`.
    /// `--session-id` only pins the ID and does not reliably restore history.
    func resumeArgs(sessionID: String) -> [String] {
        return ["--resume", sessionID]
    }
}

struct Session: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let projectDir: String
    let cbcSessionID: String?
    let agentType: AgentType
    let status: SessionStatus
    let aiTitle: String?
    let gitBranch: String?
    let pid: Int
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectDir = "project_dir"
        case cbcSessionID = "cbc_session_id"
        case agentType = "agent_type"
        case status
        case aiTitle = "ai_title"
        case gitBranch = "git_branch"
        case pid
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectDir = try container.decode(String.self, forKey: .projectDir)
        cbcSessionID = try container.decodeIfPresent(String.self, forKey: .cbcSessionID)
        agentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType) ?? .codebuddy
        status = try container.decode(SessionStatus.self, forKey: .status)
        aiTitle = try container.decodeIfPresent(String.self, forKey: .aiTitle)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        pid = try container.decode(Int.self, forKey: .pid)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}

struct SessionSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let projectDir: String
    let cbcSessionID: String?
    let agentType: AgentType
    let status: SessionStatus
    let aiTitle: String?
    let gitBranch: String?
    var needsAttention: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectDir = "project_dir"
        case cbcSessionID = "cbc_session_id"
        case agentType = "agent_type"
        case status
        case aiTitle = "ai_title"
        case gitBranch = "git_branch"
        case needsAttention = "needs_attention"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projectDir = try container.decode(String.self, forKey: .projectDir)
        cbcSessionID = try container.decodeIfPresent(String.self, forKey: .cbcSessionID)
        agentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType) ?? .codebuddy
        status = try container.decode(SessionStatus.self, forKey: .status)
        aiTitle = try container.decodeIfPresent(String.self, forKey: .aiTitle)
        gitBranch = try container.decodeIfPresent(String.self, forKey: .gitBranch)
        needsAttention = try container.decodeIfPresent(Bool.self, forKey: .needsAttention)
    }
}

enum SessionStatus: String, Codable {
    case running
    case stopped
    case crashed
}
