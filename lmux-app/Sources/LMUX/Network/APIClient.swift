import Foundation
import LMUXCore

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case notFound
    case conflict
    case serverError(String)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .unauthorized: return "Unauthorized - check token"
        case .notFound: return "Not found"
        case .conflict: return "Conflict"
        case .serverError(let msg): return "Server error: \(msg)"
        case .decodingError(let err): return "Decode error: \(err.localizedDescription)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        }
    }
}

class APIClient: AgentSessionService {
    private var baseURL: String
    private var token: String
    private let session: URLSession

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    init() {
        self.baseURL = "http://127.0.0.1:19680"
        self.token = ""
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 1
        config.httpShouldUsePipelining = true
        config.networkServiceType = .responsiveData
        self.session = URLSession(configuration: config)
    }

    func configure(addr: String, token: String) {
        self.baseURL = "http://\(addr)"
        self.token = token
    }

    // MARK: - Sessions

    func listSessions() async throws -> [SessionSummary] {
        let data = try await get("/api/sessions")
        struct Response: Codable {
            let summaries: [SessionSummary]?
        }
        let resp = try decode(Response.self, from: data)
        return resp.summaries ?? []
    }

    /// Per-session context/cost figures for the usage statistics panel.
    func sessionUsageStats() async throws -> [SessionUsageStat] {
        struct Response: Codable {
            let stats: [SessionUsageStat]?
        }
        let data = try await get("/api/sessions/usage")
        let resp = try decode(Response.self, from: data)
        return resp.stats ?? []
    }

    func getSession(id: String) async throws -> Session {
        let data = try await get("/api/sessions/\(id)")
        struct Response: Codable {
            let session: Session
        }
        let resp = try decode(Response.self, from: data)
        return resp.session
    }

    func createSession(projectDir: String, name: String? = nil, cbcSessionID: String? = nil, agentType: AgentType = .codebuddy) async throws -> Session {
        struct Body: Codable {
            let projectDir: String
            let name: String?
            let cbcSessionID: String?
            let agentType: AgentType

            enum CodingKeys: String, CodingKey {
                case projectDir = "project_dir"
                case name
                case cbcSessionID = "cbc_session_id"
                case agentType = "agent_type"
            }
        }
        let body = Body(projectDir: projectDir, name: name, cbcSessionID: cbcSessionID, agentType: agentType)
        let data = try await post("/api/sessions", body: body)
        struct Response: Codable {
            let session: Session
        }
        let resp = try decode(Response.self, from: data)
        return resp.session
    }

    func deleteSession(id: String) async throws {
        _ = try await delete("/api/sessions/\(id)")
    }

    /// Pin (star) or unpin a session so it stays at the top of the sidebar.
    func setPinned(id: String, pinned: Bool) async throws -> Session {
        struct Body: Codable {
            let pinned: Bool
        }
        let data = try await post("/api/sessions/\(id)/pin", body: Body(pinned: pinned))
        return try decode(Session.self, from: data)
    }

    func renameSession(id: String, name: String) async throws -> Session {
        struct Body: Codable {
            let name: String
        }
        let data = try await post("/api/sessions/\(id)/rename", body: Body(name: name))
        return try decode(Session.self, from: data)
    }

    /// Apply optional field updates to an existing session. Only non-nil
    /// fields are sent; the backend leaves the others unchanged.
    func updateSession(id: String, name: String?, projectDir: String?, cbcSessionID: String?) async throws -> Session {
        var body: [String: String] = [:]
        if let name { body["name"] = name }
        if let projectDir { body["project_dir"] = projectDir }
        if let cbcSessionID { body["cbc_session_id"] = cbcSessionID }
        let data = try await post("/api/sessions/\(id)/edit", body: body)
        return try decode(Session.self, from: data)
    }

    // MARK: - AgentSessionService (unified agent endpoints)

    func findAgentSession(agent: AgentType, projectDir: String, after: Date?) async -> String? {
        struct Body: Codable {
            let agent: String
            let projectDir: String
            let after: Double?
            enum CodingKeys: String, CodingKey {
                case agent
                case projectDir = "project_dir"
                case after
            }
        }
        struct Response: Codable {
            let sessionID: String?
            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
            }
        }
        let body = Body(
            agent: agent.rawValue,
            projectDir: projectDir,
            after: after?.timeIntervalSince1970
        )
        guard let data = try? await post("/api/agent/find-session", body: body),
              let resp = try? decode(Response.self, from: data) else {
            return nil
        }
        return resp.sessionID.flatMap { $0.isEmpty ? nil : $0 }
    }

    func agentSessionValid(agent: AgentType, sessionID: String) async -> Bool {
        struct Response: Codable {
            let valid: Bool
        }
        guard let data = try? await get("/api/agent/session-valid/\(agent.rawValue)/\(sessionID)"),
              let resp = try? decode(Response.self, from: data) else {
            return false
        }
        return resp.valid
    }

    func agentContext(agent: AgentType, projectDir: String, sessionID: String) async -> (tokens: Int, contextWindow: Int, model: String?, awaitingInput: Bool)? {
        struct Body: Codable {
            let agent: String
            let projectDir: String
            let sessionID: String
            enum CodingKeys: String, CodingKey {
                case agent
                case projectDir = "project_dir"
                case sessionID = "session_id"
            }
        }
        struct Response: Codable {
            let tokens: Int
            let contextWindow: Int
            let model: String?
            /// Only the codebuddy branch reports this; absent values mean the
            /// agent is not waiting (claude, or an older backend).
            let awaitingInput: Bool?
            enum CodingKeys: String, CodingKey {
                case tokens
                case contextWindow = "context_window"
                case model
                case awaitingInput = "awaiting_input"
            }
        }
        guard let data = try? await post("/api/agent/context", body: Body(agent: agent.rawValue, projectDir: projectDir, sessionID: sessionID)),
              let resp = try? decode(Response.self, from: data) else {
            return nil
        }
        return (resp.tokens, resp.contextWindow, resp.model, resp.awaitingInput ?? false)
    }

    /// File-level list of every agent conversation, optionally filtered to one
    /// agent and/or one project directory. agent "" and projectDir "" mean all.
    /// Conversations already bound to an lmux session are excluded by the
    /// backend; `hidden` reports how many were removed.
    func agentConversations(agent: String?, projectDir: String?) async throws -> (conversations: [AgentConversation], hidden: Int) {
        struct Response: Codable {
            let conversations: [AgentConversation]
            let hidden: Int?
        }
        // URLComponents (not urlQueryAllowed) so values containing "+", "&" or
        // "=" survive: those are legal in a path but meaningful in a query, and
        // a directory like /Users/x/A+B used to arrive as "A B" and match
        // nothing.
        var components = URLComponents()
        components.path = "/api/agent/conversations"
        var items: [URLQueryItem] = []
        if let agent, !agent.isEmpty {
            items.append(URLQueryItem(name: "agent", value: agent))
        }
        if let projectDir, !projectDir.isEmpty {
            items.append(URLQueryItem(name: "project_dir", value: projectDir))
        }
        if !items.isEmpty {
            components.queryItems = items
        }
        guard let path = components.string else {
            throw APIError.invalidURL
        }
        let data = try await get(path)
        let resp = try decode(Response.self, from: data)
        return (resp.conversations, resp.hidden ?? 0)
    }

    /// Recent readable messages of one conversation for the Agent browser.
    func agentConversationPreview(agent: String, sessionID: String) async throws -> AgentConversationPreview {
        struct Body: Codable {
            let agent: String
            let sessionID: String
            enum CodingKeys: String, CodingKey {
                case agent
                case sessionID = "session_id"
            }
        }
        let data = try await post("/api/agent/conversation-preview", body: Body(agent: agent, sessionID: sessionID))
        return try decode(AgentConversationPreview.self, from: data)
    }

    /// Search the text of past conversations. `all` lifts the default recency
    /// window (recent conversations only), which costs a few seconds instead of
    /// about one; the longer timeout covers it.
    func agentSearch(query: String, agent: String, projectDir: String, all: Bool) async throws -> ConversationSearchResult {
        struct Body: Codable {
            let query: String
            let agent: String
            let projectDir: String
            let all: Bool
            enum CodingKeys: String, CodingKey {
                case query
                case agent
                case projectDir = "project_dir"
                case all
            }
        }
        let data = try await post(
            "/api/agent/search",
            body: Body(query: query, agent: agent, projectDir: projectDir, all: all),
            timeout: 30
        )
        return try decode(ConversationSearchResult.self, from: data)
    }

    /// Delete one conversation file from this machine. Irreversible and local
    /// (the sync layer never propagates deletions), so the browser confirms
    /// with the user before calling this.
    func deleteAgentConversation(agent: String, sessionID: String) async throws {
        struct Body: Codable {
            let agent: String
            let sessionID: String
            enum CodingKeys: String, CodingKey {
                case agent
                case sessionID = "session_id"
            }
        }
        _ = try await post(
            "/api/agent/conversation-delete",
            body: Body(agent: agent, sessionID: sessionID)
        )
    }

    func setCBCSessionID(sessionID: String, cbcSessionID: String) async throws {
        struct Body: Codable {
            let cbcSessionID: String
            enum CodingKeys: String, CodingKey {
                case cbcSessionID = "cbc_session_id"
            }
        }
        _ = try await post("/api/sessions/\(sessionID)/cbc-session", body: Body(cbcSessionID: cbcSessionID))
    }

    /// Get the session's conversation ready to be resumed from its directory,
    /// and report which conversation that is.
    ///
    /// Three things happen in the backend, in this order: a conversation that
    /// moved on (/clear inside the agent) is followed, the file is
    /// moved into the session's directory's folder, and the cwd recorded inside
    /// it is made to agree with that directory. The returned id is the one to
    /// resume — nil when the call could not be made, so the caller falls back to
    /// the id it already had.
    func prepareConversation(sessionID: String) async -> String? {
        struct Response: Codable {
            let prepared: Bool?
            let conversationID: String?
            enum CodingKeys: String, CodingKey {
                case prepared
                case conversationID = "conversation_id"
            }
        }
        guard let data = try? await post("/api/sessions/\(sessionID)/prepare-conversation", body: Optional<String>.none),
              let resp = try? decode(Response.self, from: data),
              let id = resp.conversationID, !id.isEmpty else { return nil }
        return id
    }

    /// Point the session at the conversation its own moved on to after /clear
    /// inside the agent. `followed` says whether it changed.
    func followConversation(sessionID: String) async -> Bool {
        struct Response: Codable { let followed: Bool? }
        guard let data = try? await post("/api/sessions/\(sessionID)/follow-conversation", body: Optional<String>.none),
              let resp = try? decode(Response.self, from: data) else { return false }
        return resp.followed ?? false
    }

    /// Ask the backend to give the session the directory its agent went to work
    /// in, if it has not been given one by hand. The backend works the directory
    /// out from the conversation and decides; `adopted` says whether it took.
    func adoptWorkDir(sessionID: String) async -> Bool {
        struct Response: Codable { let adopted: Bool? }
        guard let data = try? await post("/api/sessions/\(sessionID)/work-dir", body: Optional<String>.none),
              let resp = try? decode(Response.self, from: data) else { return false }
        return resp.adopted ?? false
    }

    /// Where a conversation's file actually is, and whether `projectDir` is the
    /// directory that owns it. `found == false` means no file has that
    /// conversation id.
    func locateConversation(agent: AgentType, sessionID: String, projectDir: String) async -> ConversationLocation? {
        struct Body: Codable {
            let agent: String
            let sessionID: String
            let projectDir: String
            enum CodingKeys: String, CodingKey {
                case agent
                case sessionID = "session_id"
                case projectDir = "project_dir"
            }
        }
        struct Response: Codable {
            let found: Bool
            let projectDir: String?
            let matches: Bool?
            enum CodingKeys: String, CodingKey {
                case found, matches
                case projectDir = "project_dir"
            }
        }
        guard let data = try? await post("/api/agent/conversation-location", body: Body(agent: agent.rawValue, sessionID: sessionID, projectDir: projectDir)),
              let resp = try? decode(Response.self, from: data) else {
            return nil
        }
        return ConversationLocation(
            found: resp.found,
            projectDir: resp.projectDir,
            matches: resp.matches ?? true
        )
    }

    // MARK: - Session export / import

    /// Fetches a self-contained export bundle for a session's conversation.
    /// Pass `since` (byte offset) to fetch only the appended JSONL portion —
    /// the bundle's `content` then holds the increment and `offset` the new
    /// total size.
    func exportSession(sessionID: String, since: Int64 = 0) async throws -> SessionExportBundle {
        var url = "/api/sessions/\(sessionID)/export"
        if since > 0 {
            url += "?since=\(since)"
        }
        let data = try await get(url, timeout: Self.heavyTransferTimeout)
        return try decode(SessionExportBundle.self, from: data)
    }

    /// Imports a conversation bundle, optionally resolving a conflict by
    /// overwriting the existing session ("overwrite") or creating an
    /// independent copy ("new"). Throws `APIError.conflict` when a session
    /// already exists and no conflict mode is given.
    func importSession(_ bundle: SessionExportBundle, projectDir: String, conflictMode: String?) async throws -> Session {
        struct Body: Codable {
            let name: String
            let agentType: String
            let projectDir: String
            let cbcSessionID: String
            let content: String
            let conflictMode: String?
            enum CodingKeys: String, CodingKey {
                case name
                case agentType = "agent_type"
                case projectDir = "project_dir"
                case cbcSessionID = "cbc_session_id"
                case content
                case conflictMode = "conflict_mode"
            }
        }
        let body = Body(
            name: bundle.name,
            agentType: bundle.agentType,
            projectDir: projectDir,
            cbcSessionID: bundle.cbcSessionID,
            content: bundle.content,
            conflictMode: conflictMode
        )
        let data = try await post("/api/sessions/import", body: body, timeout: Self.heavyTransferTimeout)
        struct Response: Codable {
            let session: Session
        }
        let resp = try decode(Response.self, from: data)
        return resp.session
    }

    // MARK: - Health

    func healthCheck() async -> Bool {
        do {
            _ = try await get("/api/health")
            return true
        } catch {
            return false
        }
    }

    // MARK: - HTTP Methods

    /// Import/export transfer whole conversations (100MB+ of JSON); the 10s
    /// default request timeout is tuned for polling endpoints and kills the
    /// bundle transfer long before the backend answers.
    private static let heavyTransferTimeout: TimeInterval = 300

    private func buildRequest(_ path: String, timeout: TimeInterval? = nil) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeout {
            req.timeoutInterval = timeout
        }
        return req
    }

    private func get(_ path: String, timeout: TimeInterval? = nil) async throws -> Data {
        var req = try buildRequest(path, timeout: timeout)
        req.httpMethod = "GET"
        return try await perform(req)
    }

    private func post<T: Encodable>(_ path: String, body: T?, timeout: TimeInterval? = nil) async throws -> Data {
        var req = try buildRequest(path, timeout: timeout)
        req.httpMethod = "POST"
        if let body = body {
            // Session imports encode 100MB+ of JSON; keep that work off the
            // calling (main) thread so the UI doesn't freeze mid-transfer.
            req.httpBody = try await Task.detached(priority: .userInitiated) {
                try Self.encoder.encode(body)
            }.value
        }
        return try await perform(req)
    }

    private func delete(_ path: String) async throws -> Data {
        var req = try buildRequest(path)
        req.httpMethod = "DELETE"
        return try await perform(req)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch http.statusCode {
        case 200, 201:
            return data
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 409:
            throw APIError.conflict
        default:
            if let err = try? Self.decoder.decode([String: String].self, from: data),
               let msg = err["error"] {
                throw APIError.serverError(msg)
            }
            throw APIError.serverError("HTTP \(http.statusCode)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}
