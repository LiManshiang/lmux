import Foundation

/// Persists running session metadata so processes can be re-launched on app restart.
enum SessionRestore {
    struct Entry: Codable {
        let sessionID: String
        let projectDir: String
        let cbcSessionID: String?
    }

    private static var restoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("lmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("restore.json")
    }

    /// Save a session to the restore list.
    static func save(sessionID: String, projectDir: String, cbcSessionID: String?) {
        var entries = load()
        entries.removeAll { $0.sessionID == sessionID }
        entries.append(Entry(sessionID: sessionID, projectDir: projectDir, cbcSessionID: cbcSessionID))
        save(entries)
    }

    /// Remove a session from the restore list.
    static func remove(sessionID: String) {
        var entries = load()
        entries.removeAll { $0.sessionID == sessionID }
        save(entries)
    }

    /// Load all sessions that should be restored.
    static func loadAll() -> [Entry] {
        load()
    }

    /// Clear the restore list.
    static func clearAll() {
        save([])
    }

    private static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: restoreURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: restoreURL, options: .atomic)
    }
}
