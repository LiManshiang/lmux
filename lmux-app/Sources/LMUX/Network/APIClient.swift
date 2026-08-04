import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case notFound
    case serverError(String)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .invalidResponse: return "Invalid response"
        case .unauthorized: return "Unauthorized - check token"
        case .notFound: return "Not found"
        case .serverError(let msg): return "Server error: \(msg)"
        case .decodingError(let err): return "Decode error: \(err.localizedDescription)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        }
    }
}

class APIClient {
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
            let summaries: [SessionSummary]
        }
        let resp = try decode(Response.self, from: data)
        return resp.summaries
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

    func renameSession(id: String, name: String) async throws -> Session {
        struct Body: Codable {
            let name: String
        }
        let data = try await post("/api/sessions/\(id)/rename", body: Body(name: name))
        return try decode(Session.self, from: data)
    }

    func restoreAll() async throws -> Int {
        let data = try await post("/api/restore", body: Optional<String>.none)
        struct Response: Codable {
            let restored: Int
        }
        let resp = try decode(Response.self, from: data)
        return resp.restored
    }

    func findCodebuddySession(projectDir: String) async throws -> String? {
        struct Body: Codable {
            let projectDir: String
            enum CodingKeys: String, CodingKey {
                case projectDir = "project_dir"
            }
        }
        let data = try await post("/api/codebuddy/find-session", body: Body(projectDir: projectDir))
        struct Response: Codable {
            let sessionID: String?
            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
            }
        }
        let resp = try decode(Response.self, from: data)
        return resp.sessionID.flatMap { $0.isEmpty ? nil : $0 }
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

    private func buildRequest(_ path: String) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func get(_ path: String) async throws -> Data {
        var req = try buildRequest(path)
        req.httpMethod = "GET"
        return try await perform(req)
    }

    private func post<T: Encodable>(_ path: String, body: T?) async throws -> Data {
        var req = try buildRequest(path)
        req.httpMethod = "POST"
        if let body = body {
            req.httpBody = try Self.encoder.encode(body)
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
