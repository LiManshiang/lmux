import Foundation

/// How a session should be connected for a given agent.
enum AgentConnectDecision {
    case resume(sessionID: String) // resume an existing conversation
    case fresh                     // start the agent without an ID (new conversation)
    case bash                      // fall back to a plain shell
}

/// Result of matching a process command line against an agent. nil means the
/// command line is not this agent; a non-nil match means it is, even when
/// there is no resumable session ID (e.g. claude started fresh).
struct AgentMatch {
    let sessionID: String?
}

/// Context usage for the sidebar (percentage + estimated credit).
struct ContextUsageInfo {
    let tokens: Int
    let contextWindow: Int
    let credit: Double?
    var percent: Int {
        contextWindow > 0 ? Int((Double(tokens) / Double(contextWindow) * 100).rounded()) : 0
    }
}

/// Network operations an agent provider may need. Implemented by APIClient.
protocol AgentSessionService {
    func findAgentSession(agent: AgentType, projectDir: String) async -> String?
    func agentSessionValid(agent: AgentType, sessionID: String) async -> Bool
    func agentContext(agent: AgentType, projectDir: String, sessionID: String) async -> (tokens: Int, contextWindow: Int, credit: Double)?
}

/// Encapsulates everything that is agent-specific. Main flow (connect,
/// restore, detection) only depends on this protocol — adding a new agent is
/// just a new provider, existing agents are untouched.
protocol AgentProvider {
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

extension AgentProvider {
    /// Extract --resume/--session-id <id> from an agent command line.
    func extractSessionID(from cmdLine: String) -> String? {
        let components = cmdLine.components(separatedBy: " ")
        for i in 0..<(components.count - 1) {
            let arg = components[i]
            if arg == "--session-id" || arg == "--resume"
                || arg.hasPrefix("--session-id=") || arg.hasPrefix("--resume=") {
                if arg.contains("=") {
                    return arg.components(separatedBy: "=").last
                } else {
                    return components[i + 1]
                }
            }
        }
        return nil
    }
}

extension AgentType {
    var provider: AgentProvider {
        switch self {
        case .codebuddy: return CodebuddyProvider()
        case .claude: return ClaudeProvider()
        }
    }

    /// Higher wins when multiple agents are detected as descendants.
    var detectionPriority: Int {
        switch self {
        case .codebuddy: return 0
        case .claude: return 1
        }
    }
}

/// Locates agent executables on disk. Kept off the main actor so providers
/// can call it from any context.
enum AgentBinaryLocator {
    static var cache: [String: String] = [:]

    /// Locate an agent executable. `preferred` marks the ideal binary (e.g.
    /// native arm64 claude); `acceptable` allows a usable fallback (e.g. an
    /// x86 claude) when no preferred one exists. Anything failing both is
    /// skipped (broken stubs).
    static func findAgentPath(
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
    static func isRealClaudeBinary(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
              let size = attrs[.size] as? Int else {
            return false
        }
        return size > 1_000_000
    }

    /// True when claude.exe is a native arm64 Mach-O (or a universal binary).
    /// x86_64 builds run under Rosetta and warn about AVX / can crash.
    static func isArm64ClaudeBinary(_ path: String) -> Bool {
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

struct CodebuddyProvider: AgentProvider {
    var type: AgentType { .codebuddy }
    var executableName: String { "codebuddy-code" }
    var launchArgs: [String] { ["--permission-mode", "auto", "-y"] }
    func resumeArgs(sessionID: String) -> [String] { ["--resume", sessionID] }

    func prepareEnvironment(projectDir: String, env: inout [String: String]) {
        // CodeBuddy needs no special env/trust handling.
    }

    func resolveSession(cbcSessionID: String?, projectDir: String, allowHistoryLookup: Bool, service: AgentSessionService) async -> AgentConnectDecision {
        if let cbc = cbcSessionID, !cbc.isEmpty,
           await service.agentSessionValid(agent: .codebuddy, sessionID: cbc) {
            return .resume(sessionID: cbc)
        }
        if allowHistoryLookup,
           let found = await service.findAgentSession(agent: .codebuddy, projectDir: projectDir),
           !found.isEmpty {
            return .resume(sessionID: found)
        }
        // No valid conversation and no history to look up: plain shell.
        return .bash
    }

    func findBinaryPath() -> String? {
        AgentBinaryLocator.findAgentPath(name: executableName)
    }

    func detectProcess(cmdLine: String) -> AgentMatch? {
        let lower = cmdLine.lowercased()
        if lower.contains("codebuddy-code") || lower.contains("codebuddy") {
            return AgentMatch(sessionID: extractSessionID(from: cmdLine))
        }
        return nil
    }

    func contextUsage(cbcSessionID: String?, projectDir: String, service: AgentSessionService) async -> ContextUsageInfo? {
        guard let cbcSessionID, !cbcSessionID.isEmpty,
              let info = await service.agentContext(agent: .codebuddy, projectDir: projectDir, sessionID: cbcSessionID),
              info.contextWindow > 0, info.tokens > 0 else {
            return nil
        }
        return ContextUsageInfo(tokens: info.tokens, contextWindow: info.contextWindow, credit: info.credit > 0 ? info.credit : nil)
    }
}

// MARK: - Claude

struct ClaudeProvider: AgentProvider {
    var type: AgentType { .claude }
    var executableName: String { "claude" }
    var launchArgs: [String] { ["--dangerously-skip-permissions"] }
    func resumeArgs(sessionID: String) -> [String] { ["--resume", sessionID] }

    func prepareEnvironment(projectDir: String, env: inout [String: String]) {
        // The app inherits CLAUDE_*/CODEBUDDY_* variables from codebuddy
        // (notably CLAUDE_SESSION_ID pointing at a codebuddy conversation).
        // claude sees those and refuses to render its TUI. Strip them.
        env = env.filter { !$0.key.hasPrefix("CLAUDE_") && !$0.key.hasPrefix("CODEBUDDY") }
        // claude shows a workspace trust dialog on first run in a directory;
        // pre-accept it so it doesn't block the embedded terminal.
        SessionRestore.acceptClaudeTrust(directory: projectDir)
    }

    func resolveSession(cbcSessionID: String?, projectDir: String, allowHistoryLookup: Bool, service: AgentSessionService) async -> AgentConnectDecision {
        var cbc = cbcSessionID
        if let id = cbc, !id.isEmpty,
           await service.agentSessionValid(agent: .codebuddy, sessionID: id) {
            // The ID is a valid codebuddy conversation (saved from a wrongly
            // launched claude --resume <codebuddy-id>); never pass it to claude.
            cbc = nil
        }
        if (cbc == nil || cbc!.isEmpty) && allowHistoryLookup {
            cbc = await service.findAgentSession(agent: .claude, projectDir: projectDir)
        }
        if let id = cbc, !id.isEmpty {
            return .resume(sessionID: id)
        }
        // A fresh agent session is only appropriate when this is known to be
        // an agent session; otherwise keep the plain shell.
        return allowHistoryLookup ? .fresh : .bash
    }

    func findBinaryPath() -> String? {
        // Prefer the native arm64 build; skip broken postinstall stubs and
        // x86_64 (Rosetta) builds that warn about AVX / can crash.
        AgentBinaryLocator.findAgentPath(
            name: executableName,
            preferred: AgentBinaryLocator.isArm64ClaudeBinary,
            acceptable: AgentBinaryLocator.isRealClaudeBinary
        )
    }

    func detectProcess(cmdLine: String) -> AgentMatch? {
        let lower = cmdLine.lowercased()
        if lower.contains("claude") && !lower.contains("claudecode") {
            return AgentMatch(sessionID: extractSessionID(from: cmdLine))
        }
        return nil
    }

    func contextUsage(cbcSessionID: String?, projectDir: String, service: AgentSessionService) async -> ContextUsageInfo? {
        guard let cbcSessionID, !cbcSessionID.isEmpty,
              let info = await service.agentContext(agent: .claude, projectDir: projectDir, sessionID: cbcSessionID),
              info.contextWindow > 0, info.tokens > 0 else {
            return nil
        }
        return ContextUsageInfo(tokens: info.tokens, contextWindow: info.contextWindow, credit: nil)
    }
}
