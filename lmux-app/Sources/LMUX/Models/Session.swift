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
    let pinned: Bool
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
        case pinned
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
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
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
    let pinned: Bool
    var needsAttention: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectDir = "project_dir"
        case cbcSessionID = "cbc_session_id"
        case agentType = "agent_type"
        case status
        case aiTitle = "ai_title"
        case gitBranch = "git_branch"
        case pinned
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
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        needsAttention = try container.decodeIfPresent(Bool.self, forKey: .needsAttention)
    }
}

enum SessionStatus: String, Codable {
    case running
    case stopped
    case crashed
}

/// Context/cost figures for one session, shown in the usage statistics panel.
struct SessionUsageStat: Codable, Identifiable {
    let id: String
    let name: String
    let agentType: String
    let model: String?
    let tokens: Int64
    let contextWindow: Int64
    let credit: Double

    var percent: Double {
        guard contextWindow > 0 else { return 0 }
        return Double(tokens) / Double(contextWindow) * 100
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case agentType = "agent_type"
        case model
        case tokens
        case contextWindow = "context_window"
        case credit
    }
}

/// Self-contained export of a session's conversation: agent type, project
/// directory, conversation ID, and the full raw JSONL content. Serialized to
/// and from a `.lmuxsession` file.
struct SessionExportBundle: Codable {
    let format: String?
    let version: Int?
    var name: String
    var agentType: String
    var projectDir: String
    /// Last working directory the agent recorded in its conversation (where
    /// it actually worked) at export time. Used as the auto import target;
    /// nil for bundles exported before this field existed.
    var cwd: String?
    var cbcSessionID: String
    let exportedAt: String?
    var content: String
    /// Byte offset up to which `content` is current (file size). When the
    /// export was requested with `since`, `content` holds only the appended
    /// portion after that offset and `offset` is the new total size.
    var offset: Int64?
    /// Unix seconds the underlying JSONL was last modified (sync change detection).
    let contentModifiedAt: Int64?
    /// Device that produced this export; used by cross-device sync to avoid
    /// re-importing one's own files.
    var deviceId: String?

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case name
        case agentType = "agent_type"
        case projectDir = "project_dir"
        case cwd
        case cbcSessionID = "cbc_session_id"
        case exportedAt = "exported_at"
        case content
        case offset
        case contentModifiedAt = "content_modified_at"
        case deviceId = "device_id"
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
