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

/// Where a conversation's file is, and whether a given project directory owns
/// it.
///
/// A session's `project_dir` has to be the directory the conversation was
/// launched in: the agent resolves `--resume <id>` inside the project folder
/// derived from its working directory, so a session pointing anywhere else
/// cannot resume at all — the terminal prints "No conversation found with
/// session ID". `projectDir` is a path to offer the user, and is empty when the
/// conversation's records do not pin one down; `matches` answers the question
/// by comparison, so it stays exact either way.
struct ConversationLocation: Hashable {
    let found: Bool
    let projectDir: String?
    let matches: Bool
}

// MARK: - Content search

/// One matching message found while searching conversation text.
struct ConversationSearchHit: Codable, Hashable, Identifiable {
    let role: String
    /// The match plus a little context on both sides, elided with "…".
    let snippet: String
    let line: Int

    var id: Int { line }
}

/// The hits found inside a single conversation.
struct ConversationSearchGroup: Codable, Hashable, Identifiable {
    let conversation: AgentConversation
    let hits: [ConversationSearchHit]

    var id: String { conversation.id }
}

/// Outcome of a content search: which conversations matched, how much was
/// scanned, and whether the scan hit its limits.
struct ConversationSearchResult: Codable {
    let results: [ConversationSearchGroup]
    let scanned: Int
    let scannedBytes: Int64
    let truncated: Bool
    let timedOut: Bool
    let elapsedMS: Int64

    enum CodingKeys: String, CodingKey {
        case results
        case scanned
        case scannedBytes = "scanned_bytes"
        case truncated
        case timedOut = "timed_out"
        case elapsedMS = "elapsed_ms"
    }

    /// Drops one conversation's hits — used after deleting it, so the other
    /// matches stay on screen instead of the whole result being discarded.
    func removing(conversationID: String) -> ConversationSearchResult {
        let kept = results.filter { $0.conversation.id != conversationID }
        guard kept.count != results.count else { return self }
        return ConversationSearchResult(
            results: kept,
            scanned: scanned,
            scannedBytes: scannedBytes,
            truncated: truncated,
            timedOut: timedOut,
            elapsedMS: elapsedMS
        )
    }
}
