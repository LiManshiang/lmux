import Foundation

/// Supported AI agents. Behavior is encapsulated in each agent's AgentProvider.
public enum AgentType: String, Codable, CaseIterable, Sendable {
    case codebuddy
    case claude

    public var displayName: String {
        switch self {
        case .codebuddy: return "CodeBuddy"
        case .claude: return "Claude Code"
        }
    }

    public var symbolName: String {
        switch self {
        case .codebuddy: return "hammer.fill"
        case .claude: return "sparkle"
        }
    }

    public var executableName: String {
        switch self {
        case .codebuddy: return "codebuddy-code"
        case .claude: return "claude"
        }
    }

    public var launchArgs: [String] {
        switch self {
        case .codebuddy: return ["--permission-mode", "auto", "-y"]
        case .claude: return ["--dangerously-skip-permissions"]
        }
    }

    /// Arguments that resume an existing conversation by session ID.
    public func resumeArgs(sessionID: String) -> [String] {
        return ["--resume", sessionID]
    }
}
