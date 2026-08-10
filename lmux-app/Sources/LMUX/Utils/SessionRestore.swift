import Foundation

/// Persists running session metadata so processes can be re-launched on app restart.
enum SessionRestore {
    /// Tracks whether the session should restore as a bash terminal or as a direct agent launch.
    enum LaunchMode: String, Codable {
        case bash
        case agent
    }

    struct Entry: Codable {
        let sessionID: String
        let projectDir: String
        let cbcSessionID: String?
        let agentType: AgentType?
        /// How this session was launched. On restore we use the same mode.
        /// .bash  → restore bash terminal via connectBash()
        /// .agent → restore agent process directly via connect()
        let launchMode: LaunchMode?

        init(sessionID: String, projectDir: String, cbcSessionID: String?, agentType: AgentType?, launchMode: LaunchMode?) {
            self.sessionID = sessionID
            self.projectDir = projectDir
            self.cbcSessionID = cbcSessionID
            self.agentType = agentType
            self.launchMode = launchMode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            projectDir = try container.decode(String.self, forKey: .projectDir)
            cbcSessionID = try container.decodeIfPresent(String.self, forKey: .cbcSessionID)
            agentType = try container.decodeIfPresent(AgentType.self, forKey: .agentType)
            launchMode = try container.decodeIfPresent(LaunchMode.self, forKey: .launchMode)
        }

        enum CodingKeys: String, CodingKey {
            case sessionID, projectDir
            case cbcSessionID = "cbcSessionID"
            case agentType
            case launchMode
        }
    }

    // MARK: - Caching & I/O

    private static let restoreURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("lmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("restore.json")
    }()

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); return d }()

    /// All I/O runs on this queue to keep it off the main actor.
    private static let ioQueue = DispatchQueue(label: "lmux.restore", qos: .utility)

    /// In-memory cache to avoid reading the file on every access.
    private static var cachedEntries: [Entry]?
    /// Debounced write work item for coalescing rapid saves.
    private static var writeWorkItem: DispatchWorkItem?

    // MARK: - Public API

    /// Save a session to the restore list. Updates in-memory cache immediately;
    /// the disk write is coalesced and runs on a background queue.
    static func save(sessionID: String, projectDir: String, cbcSessionID: String?, agentType: AgentType = .codebuddy, launchMode: LaunchMode = .bash) {
        ioQueue.async {
            var entries = cachedEntries ?? loadFromDisk()
            entries.removeAll { $0.sessionID == sessionID }
            entries.append(Entry(sessionID: sessionID, projectDir: projectDir, cbcSessionID: cbcSessionID, agentType: agentType, launchMode: launchMode))
            cachedEntries = entries
            scheduleWrite()
        }
    }

    /// Remove a session from the restore list.
    static func remove(sessionID: String) {
        ioQueue.async {
            var entries = cachedEntries ?? loadFromDisk()
            entries.removeAll { $0.sessionID == sessionID }
            cachedEntries = entries
            scheduleWrite()
        }
    }

    /// Load all sessions that should be restored. Returns from the in-memory
    /// cache when available; disk is only read once. Runs on ioQueue so callers
    /// (including the main actor) never block on file I/O.
    static func loadAll() -> [Entry] {
        return ioQueue.sync {
            let entries = cachedEntries ?? loadFromDisk()
            cachedEntries = entries
            return entries
        }
    }

    /// Clear the restore list.
    static func clearAll() {
        ioQueue.async {
            cachedEntries = []
            scheduleWrite()
        }
    }

    // MARK: - Private

    private static func loadFromDisk() -> [Entry] {
        guard let data = try? Data(contentsOf: restoreURL),
              let entries = try? decoder.decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func scheduleWrite() {
        writeWorkItem?.cancel()
        let work = DispatchWorkItem {
            guard let entries = cachedEntries else { return }
            guard let data = try? encoder.encode(entries) else { return }
            try? data.write(to: restoreURL, options: .atomic)
        }
        writeWorkItem = work
        ioQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Mark a directory as trusted in ~/.claude.json so `claude` skips its
    /// workspace trust dialog when lmux launches it (the dialog can't be
    /// answered from the embedded terminal).
    static func acceptClaudeTrust(directory: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.claude.json")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var projects = json["projects"] as? [String: Any] ?? [:]
        var entry = projects[directory] as? [String: Any] ?? [:]
        entry["hasTrustDialogAccepted"] = true
        projects[directory] = entry
        json["projects"] = projects
        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url)
        }
    }
}
