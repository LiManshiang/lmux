import Foundation

/// How a session should be connected for a given agent.
public enum AgentConnectDecision {
    case resume(sessionID: String) // resume an existing conversation
    case fresh                     // start the agent without an ID (new conversation)
    case bash                      // fall back to a plain shell
}

/// Result of matching a process command line against an agent. nil means the
/// command line is not this agent; a non-nil match means it is, even when
/// there is no resumable session ID (e.g. claude started fresh).
public struct AgentMatch {
    public let sessionID: String?
    /// True when the ID came from `--resume <id>` (an explicit, authoritative
    /// "continue this conversation"), false for `--session-id <id>` (lmux
    /// assigns a fresh isolated ID at launch) or a fresh launch.
    public let isResume: Bool

    public init(sessionID: String?, isResume: Bool = false) {
        self.sessionID = sessionID
        self.isResume = isResume
    }
}

/// Context usage for the sidebar (percentage + estimated credit).
public struct ContextUsageInfo {
    public let tokens: Int
    public let contextWindow: Int
    public let credit: Double?
    public var percent: Int {
        contextWindow > 0 ? Int((Double(tokens) / Double(contextWindow) * 100).rounded()) : 0
    }
}

/// Network operations an agent provider may need. Implemented by APIClient.
public protocol AgentSessionService {
    /// Find the most recent conversation for an agent in a project.
    /// `after` optionally filters to conversations created no earlier than
    /// that instant (used to associate a freshly launched agent with its own
    /// new conversation instead of an older one from another session).
    func findAgentSession(agent: AgentType, projectDir: String, after: Date?) async -> String?
    func agentSessionValid(agent: AgentType, sessionID: String) async -> Bool
    func agentContext(agent: AgentType, projectDir: String, sessionID: String) async -> (tokens: Int, contextWindow: Int, credit: Double)?
}

/// Encapsulates everything that is agent-specific. Main flow (connect,
/// restore, detection) only depends on this protocol — adding a new agent is
/// just a new provider, existing agents are untouched.
public protocol AgentProvider {
    var type: AgentType { get }
    var executableName: String { get }
    var launchArgs: [String] { get }
    func resumeArgs(sessionID: String) -> [String]

    /// Prepare environment / trust before launching the agent.
    func prepareEnvironment(projectDir: String, env: inout [String: String])

    /// Decide how to connect: resume an existing conversation, start fresh,
    /// or fall back to bash. `allowHistoryLookup` is true for sessions known
    /// to be agent sessions (so a brand-new session doesn't unexpectedly pick
    /// up old history).
    func resolveSession(cbcSessionID: String?, projectDir: String, allowHistoryLookup: Bool, service: AgentSessionService) async -> AgentConnectDecision

    /// Absolute path to the agent binary, or nil if not found.
    func findBinaryPath() -> String?

    /// Detect this agent from a process command line. nil = not this agent;
    /// otherwise the agent matched (sessionID may be nil for a fresh session).
    func detectProcess(cmdLine: String) -> AgentMatch?

    /// Context usage (tokens / window / credit) for a conversation of this
    /// agent, or nil when unavailable. Implementation is agent-specific.
    func contextUsage(cbcSessionID: String?, projectDir: String, service: AgentSessionService) async -> ContextUsageInfo?
}

public extension AgentProvider {
    /// Extract --resume/--session-id <id> from an agent command line.
    public func extractSessionID(from cmdLine: String) -> String? {
        let components = cmdLine.components(separatedBy: " ")
        for i in 0..<components.count {
            let arg = components[i]
            if arg == "--session-id" || arg == "--resume" {
                if i + 1 < components.count {
                    return components[i + 1]
                }
                return nil
            }
            if arg.hasPrefix("--session-id=") || arg.hasPrefix("--resume=") {
                return arg.components(separatedBy: "=").last
            }
        }
        return nil
    }

    /// The conversation to associate with this session after agent detection.
    ///
    /// A `--resume`/`--session-id` seen on the command line is authoritative.
    /// When the agent was launched fresh (no resumable ID — common for claude
    /// started by hand inside a shell), fall back to the project's most recent
    /// conversation so a restart can resume the right one. History lookup is
    /// skipped for brand-new sessions so they never pick up another session's
    /// conversation.
    ///
    /// `notBefore` (the agent process start time) scopes the fallback to
    /// conversations created after the launch, so a fresh claude is associated
    /// with its own new conversation rather than an older one that belongs to
    /// another session.
    public func detectionSessionID(
        cmdLineSessionID: String?,
        allowHistoryLookup: Bool,
        projectDir: String,
        notBefore: Date? = nil,
        service: AgentSessionService
    ) async -> String? {
        guard allowHistoryLookup else { return nil }

        // An explicit `--resume <id>` on the command line is authoritative.
        // It means the agent (or lmux restoring it) explicitly chose that
        // conversation, and it stays authoritative even when the user later
        // /resume's inside the agent — argv doesn't change, so find-session's
        // timestamp guess must never override it. Overriding it is what made
        // a working lmux session silently rebind to another session's fresh
        // conversation.
        if let id = cmdLineSessionID, !id.isEmpty {
            return id
        }

        // Fresh launch (no --resume): the agent created its own conversation.
        // find-session returns the one whose creation time is closest to the
        // process start — each session binds to its own fresh file.
        if let notBefore {
            if let live = await service.findAgentSession(agent: type, projectDir: projectDir, after: notBefore),
               !live.isEmpty {
                return live
            }
        }
        return nil
    }
}

public extension AgentType {
    public var provider: AgentProvider {
        switch self {
        case .codebuddy: return CodebuddyProvider()
        case .claude: return ClaudeProvider()
        }
    }

    /// Higher wins when multiple agents are detected as descendants.
    public var detectionPriority: Int {
        switch self {
        case .codebuddy: return 0
        case .claude: return 1
        }
    }
}

/// Locates agent executables on disk. Kept off the main actor so providers
/// can call it from any context.
public enum AgentBinaryLocator {
    public static var cache: [String: String] = [:]

    /// Locate an agent executable. `preferred` marks the ideal binary (e.g.
    /// native arm64 claude); `acceptable` allows a usable fallback (e.g. an
    /// x86 claude) when no preferred one exists. Anything failing both is
    /// skipped (broken stubs).
    public static func findAgentPath(
        name: String,
        preferred: @escaping (String) -> Bool = { _ in true },
        acceptable: @escaping (String) -> Bool = { _ in true }
    ) -> String? {
        if let cached = cache[name],
           FileManager.default.isExecutableFile(atPath: cached),
           preferred(cached) || acceptable(cached) {
            return cached
        }

        func consider(_ p: String) -> String? {
            guard FileManager.default.isExecutableFile(atPath: p) else { return nil }
            if preferred(p) { return p }
            // Acceptable binaries (e.g. x86 claude) are kept as a fallback and
            // only used when no preferred binary exists anywhere.
            if acceptable(p) && fallback == nil { fallback = p }
            return nil
        }
        var fallback: String?
        let home = NSHomeDirectory()

        // 1. Local fixed install locations first (this machine, not a mounted
        // volume), so a claude installed on another machine's shared drive
        // doesn't shadow this machine's own install.
        for p in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)"] {
            if let found = consider(p) {
                cache[name] = found
                return found
            }
        }

        // 2. PATH, preferring local directories over mounted volumes.
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        for dir in pathDirs where !dir.hasPrefix("/Volumes/") {
            let p = "\(dir)/\(name)"
            if let found = consider(p) {
                cache[name] = found
                return found
            }
        }

        // 3. Local nvm (~/.nvm).
        let localNvm = "\(home)/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: localNvm) {
            for entry in entries {
                let p = "\(localNvm)/\(entry)/bin/\(name)"
                if let found = consider(p) {
                    cache[name] = found
                    return found
                }
            }
        }

        // 4. nvm installations on mounted volumes (shared drives, other
        // machines). Last resort before PATH's volume entries.
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for vol in volumes where vol != "Macintosh HD" && !vol.hasPrefix(".") {
            let nvmBase = "/Volumes/\(vol)/OpenSource/nvm/versions/node"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
                for entry in entries {
                    let p = "\(nvmBase)/\(entry)/bin/\(name)"
                    if let found = consider(p) {
                        cache[name] = found
                        return found
                    }
                }
            }
        }

        // 5. PATH entries on mounted volumes.
        for dir in pathDirs where dir.hasPrefix("/Volumes/") {
            let p = "\(dir)/\(name)"
            if let found = consider(p) {
                cache[name] = found
                return found
            }
        }

        // 6. Check NVM_DIR from environment.
        if let nvmDir = ProcessInfo.processInfo.environment["NVM_DIR"] {
            if let found = consider("\(nvmDir)/\(name)") {
                cache[name] = found
                return found
            }
        }

        // 7. Any acceptable fallback seen along the way (e.g. x86 claude).
        if let fallback {
            cache[name] = fallback
            return fallback
        }

        let finalFallback = "/opt/homebrew/bin/\(name)"
        cache[name] = finalFallback
        return finalFallback
    }

    /// claude is a symlink to .../claude.exe. A failed npm postinstall leaves
    /// a ~500-byte stub that errors at launch ("native binary not installed");
    /// only accept a real native binary (>1MB).
    public static func isRealClaudeBinary(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              let size = attrs[.size] as? Int else {
            return false
        }
        return size > 1_000_000
    }

    /// True when claude.exe is a native arm64 Mach-O (or a universal binary).
    /// x86_64 builds run under Rosetta and warn about AVX / can crash.
    public static func isArm64ClaudeBinary(_ path: String) -> Bool {
        guard isRealClaudeBinary(path) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: resolved)) else {
            return false
        }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 8)
        guard data.count >= 8 else { return false }
        let b = [UInt8](data)
        // Mach-O 64-bit magic: 0xFEEDFACF (big-endian on disk) / 0xCFFAEDFE (LE).
        let magic = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        if magic == 0xCAFEBABE { return true } // universal binary
        guard magic == 0xFEEDFACF || magic == 0xCFFAEDFE else { return false }
        let cputype = UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
        return cputype == 0x0100_000C // CPU_TYPE_ARM64
    }
}

// MARK: - CodeBuddy

public struct CodebuddyProvider: AgentProvider {
    public var type: AgentType { .codebuddy }
    public var executableName: String { "codebuddy-code" }
    public var launchArgs: [String] { ["--permission-mode", "auto", "-y"] }
    public func resumeArgs(sessionID: String) -> [String] { ["--resume", sessionID] }

    public func prepareEnvironment(projectDir: String, env: inout [String: String]) {
        // CodeBuddy needs no special env/trust handling.
    }

    public func resolveSession(cbcSessionID: String?, projectDir: String, allowHistoryLookup: Bool, service: AgentSessionService) async -> AgentConnectDecision {
        if let cbc = cbcSessionID, !cbc.isEmpty,
           await service.agentSessionValid(agent: .codebuddy, sessionID: cbc) {
            return .resume(sessionID: cbc)
        }
        // No resumable ID.
        // - New session (allowHistoryLookup=false): plain shell. Agent
        //   detection will upgrade if the user launches an agent manually.
        // - Restore of a known agent session (allowHistoryLookup=true): start
        //   a fresh codebuddy conversation. A freshly launched codebuddy that
        //   created a conversation is associated by agent detection with a
        //   notBefore-scoped lookup, which writes the ID into restore.json —
        //   so recovery has a non-nil ID here when one exists. An empty ID on
        //   an agent session means the user wants a new conversation, not a
        //   shell.
        if cbcSessionID == nil || cbcSessionID!.isEmpty {
            return allowHistoryLookup ? .fresh : .bash
        }
        // The ID exists but is not a valid conversation for this agent. Start
        // a fresh agent conversation rather than a shell — this is still an
        // agent session, the user just has no recoverable conversation ID. Do
        // NOT fall back to the project's most recent conversation here, which
        // usually belongs to a DIFFERENT session and would make several
        // sessions all resume the same conversation.
        return allowHistoryLookup ? .fresh : .bash
    }

    public func findBinaryPath() -> String? {
        AgentBinaryLocator.findAgentPath(name: executableName)
    }

    public func detectProcess(cmdLine: String) -> AgentMatch? {
        let lower = cmdLine.lowercased()
        if lower.contains("codebuddy-code") || lower.contains("codebuddy") {
            // `--resume <id>` is an explicit "continue this conversation".
            // `--session-id <id>` is lmux assigning a fresh isolated ID at
            // launch (the user may then /resume away from it), so it is not
            // authoritative.
            let isResume = lower.contains(" --resume ") || lower.contains("--resume=")
            return AgentMatch(sessionID: extractSessionID(from: cmdLine), isResume: isResume)
        }
        return nil
    }

    public func contextUsage(cbcSessionID: String?, projectDir: String, service: AgentSessionService) async -> ContextUsageInfo? {
        guard let cbcSessionID, !cbcSessionID.isEmpty,
              let info = await service.agentContext(agent: .codebuddy, projectDir: projectDir, sessionID: cbcSessionID),
              info.contextWindow > 0, info.tokens > 0 else {
            return nil
        }
        return ContextUsageInfo(tokens: info.tokens, contextWindow: info.contextWindow, credit: info.credit > 0 ? info.credit : nil)
    }
}

// MARK: - Claude

public struct ClaudeProvider: AgentProvider {
    public var type: AgentType { .claude }
    public var executableName: String { "claude" }
    public var launchArgs: [String] { ["--dangerously-skip-permissions"] }
    public func resumeArgs(sessionID: String) -> [String] { ["--resume", sessionID] }

    public func prepareEnvironment(projectDir: String, env: inout [String: String]) {
        // The app inherits CLAUDE_*/CODEBUDDY_* variables from codebuddy
        // (notably CLAUDE_SESSION_ID pointing at a codebuddy conversation).
        // claude sees those and refuses to render its TUI. Strip them.
        env = env.filter { !$0.key.hasPrefix("CLAUDE_") && !$0.key.hasPrefix("CODEBUDDY") }
        // claude shows a workspace trust dialog on first run in a directory;
        // pre-accept it so it doesn't block the embedded terminal.
        SessionRestore.acceptClaudeTrust(directory: projectDir)
    }

    public func resolveSession(cbcSessionID: String?, projectDir: String, allowHistoryLookup: Bool, service: AgentSessionService) async -> AgentConnectDecision {
        var cbc = cbcSessionID
        var hadProvidedCBC = (cbcSessionID != nil && !cbcSessionID!.isEmpty)
        if let id = cbc, !id.isEmpty,
           await service.agentSessionValid(agent: .codebuddy, sessionID: id) {
            // The ID is a valid codebuddy conversation (saved from a wrongly
            // launched claude --resume <codebuddy-id>); never pass it to claude.
            cbc = nil
        }
        // Look up claude history only when a session ID was explicitly
        // associated with this agent before (a codebuddy ID that was just
        // discarded, or a claude ID that failed validation). When nothing was
        // ever associated, looking up the project's most recent claude
        // conversation would wrongly resume another session's work — e.g. a
        // freshly launched claude in a new session must not pick up the
        // previous session's conversation on restart.
        if hadProvidedCBC, (cbc == nil || cbc!.isEmpty), allowHistoryLookup {
            cbc = await service.findAgentSession(agent: .claude, projectDir: projectDir, after: nil)
        }
        if let id = cbc, !id.isEmpty {
            return .resume(sessionID: id)
        }
        // A fresh agent session is only appropriate when this is known to be
        // an agent session; otherwise keep the plain shell.
        return allowHistoryLookup ? .fresh : .bash
    }

    public func findBinaryPath() -> String? {
        // Prefer the native arm64 build; skip broken postinstall stubs and
        // x86_64 (Rosetta) builds that warn about AVX / can crash.
        AgentBinaryLocator.findAgentPath(
            name: executableName,
            preferred: AgentBinaryLocator.isArm64ClaudeBinary,
            acceptable: AgentBinaryLocator.isRealClaudeBinary
        )
    }

    public func detectProcess(cmdLine: String) -> AgentMatch? {
        let lower = cmdLine.lowercased()
        if lower.contains("claude") && !lower.contains("claudecode") {
            return AgentMatch(sessionID: extractSessionID(from: cmdLine))
        }
        return nil
    }

    public func contextUsage(cbcSessionID: String?, projectDir: String, service: AgentSessionService) async -> ContextUsageInfo? {
        guard let cbcSessionID, !cbcSessionID.isEmpty,
              let info = await service.agentContext(agent: .claude, projectDir: projectDir, sessionID: cbcSessionID),
              info.contextWindow > 0, info.tokens > 0 else {
            return nil
        }
        return ContextUsageInfo(tokens: info.tokens, contextWindow: info.contextWindow, credit: nil)
    }
}


