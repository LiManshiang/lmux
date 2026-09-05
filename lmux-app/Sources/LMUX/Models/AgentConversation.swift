import Foundation

/// A raw agent conversation (a JSONL file under ~/.codebuddy/projects or
/// ~/.claude/projects) surfaced by the Agent browser. This is the
/// filesystem-level view — conversations never opened in lmux still appear
/// here, and can be resumed from any machine that has the file.
struct AgentConversation: Codable, Identifiable, Hashable {
    let agent: String
    let id: String
    let aiTitle: String?
    let summary: String?
    let cwd: String?
    /// Path of the JSONL relative to the agent projects root. The file lives
    /// under the encoded launch directory, which can differ from `cwd` after
    /// the agent cd'd elsewhere — use this to locate/copy the file.
    let fileRel: String?
    let size: Int64
    let mtime: Int64

    enum CodingKeys: String, CodingKey {
        case agent
        case id
        case aiTitle = "ai_title"
        case summary
        case cwd
        case fileRel = "file_rel"
        case size
        case mtime
    }
}

/// A readable user/assistant message shown in the Agent browser preview.
struct AgentConversationPreview: Codable {
    struct Row: Codable {
        let role: String
        let text: String
    }
    let rows: [Row]
}
