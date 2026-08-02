import Foundation

struct Session: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let projectDir: String
    let cbcSessionID: String?
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
        case status
        case aiTitle = "ai_title"
        case gitBranch = "git_branch"
        case pid
        case createdAt = "created_at"
        case updatedAt = "updated_at"
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
    let status: SessionStatus
    let aiTitle: String?
    let gitBranch: String?
    var needsAttention: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name
        case projectDir = "project_dir"
        case cbcSessionID = "cbc_session_id"
        case status
        case aiTitle = "ai_title"
        case gitBranch = "git_branch"
        case needsAttention = "needs_attention"
    }
}

enum SessionStatus: String, Codable {
    case running
    case stopped
    case crashed
}
