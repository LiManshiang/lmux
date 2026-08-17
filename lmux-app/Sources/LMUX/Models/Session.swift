import Foundation
import LMUXCore
import UniformTypeIdentifiers

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

/// Self-contained export of a session's conversation: agent type, project
/// directory, conversation ID, and the full raw JSONL content. Serialized to
/// and from a `.lmuxsession` file.
struct SessionExportBundle: Codable {
    let format: String?
    let version: Int?
    let name: String
    let agentType: String
    let projectDir: String
    let cbcSessionID: String
    let exportedAt: String?
    let content: String

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case name
        case agentType = "agent_type"
        case projectDir = "project_dir"
        case cbcSessionID = "cbc_session_id"
        case exportedAt = "exported_at"
        case content
    }

    /// Serializes the bundle to JSON data (the `.lmuxsession` file content).
    func toJSON() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes a `.lmuxsession` file into a bundle.
    static func fromJSON(_ url: URL) -> SessionExportBundle? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionExportBundle.self, from: data)
    }
}

extension UTType {
    /// The `.lmuxsession` export/import file type (a JSON document).
    static let lmuxSession = UTType(exportedAs: "com.lmux.session", conformingTo: .json)
}
