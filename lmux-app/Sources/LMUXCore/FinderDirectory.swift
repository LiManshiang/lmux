import Foundation

/// Directory resolution for the session context menu's "Open In > Finder".
///
/// The agent's last recorded working directory (agentCwd) is preferred: it is
/// what the Edit sheet prefills and reflects where the session actually works
/// (a session's DB projectDir can be a stale creation-time path, e.g. a
/// directory the conversation was imported from). The DB projectDir is the
/// fallback for sessions with no recorded cwd yet.
public enum FinderDirectory {
    /// Trimmed/whitespace-only agentCwd values are treated as absent.
    public static func resolve(projectDir: String, agentCwd: String?) -> String {
        if let agentCwd, !agentCwd.trimmingCharacters(in: .whitespaces).isEmpty {
            return agentCwd
        }
        return projectDir
    }
}
