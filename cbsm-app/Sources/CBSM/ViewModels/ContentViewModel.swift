import SwiftUI
import Combine
import AppKit

@MainActor
class ContentViewModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []
    @Published var selectedSession: SessionSummary?
    @Published var selectedFullSession: Session?
    @Published var showNewSessionSheet = false
    @Published var backendRunning = false
    @Published var backendStarting = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let api = APIClient()
    private var backendProcess: Process?
    private var pollTimer: Timer?

    // MARK: - Backend Management

    func startBackend() {
        backendStarting = true
        Task {
            // try to connect to existing backend
            if await api.healthCheck() {
                let token = loadToken()
                let addr = loadAddr()
                if let token = token, let addr = addr {
                    api.configure(addr: addr, token: token)
                    backendRunning = true
                    backendStarting = false
                    await refreshSessions()
                    startPolling()
                    return
                }
            }

            // start backend process
            await launchBackend()
        }
    }

    func retryBackend() {
        if backendProcess?.isRunning == true {
            backendProcess?.terminate()
        }
        backendStarting = true
        errorMessage = nil
        statusMessage = "Starting backend..."
        Task {
            await launchBackend()
        }
    }

    private func launchBackend() async {
        // search for cbsm binary in multiple locations
        let paths = findCBSPaths()

        var execPath: String?
        for p in paths {
            if FileManager.default.isExecutableFile(atPath: p) {
                execPath = p
                break
            }
        }

        guard let execPath = execPath else {
            backendStarting = false
            errorMessage = "cbsm backend not found. Try: cd ~/Projects/cbsm && make build"
            statusMessage = "Backend not found"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = ["--restore"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            backendProcess = process
        } catch {
            backendStarting = false
            errorMessage = "Failed to start backend: \(error.localizedDescription)"
            statusMessage = "Backend failed to start"
            return
        }

        // read token from output
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let data = pipe.fileHandleForReading.availableData
        if let output = String(data: data, encoding: .utf8) {
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("CBSM_TOKEN=") {
                    saveToken(String(line.dropFirst(11)))
                }
                if line.hasPrefix("CBSM_ADDR=") {
                    saveAddr(String(line.dropFirst(10)))
                }
            }
        }

        let token = loadToken() ?? ""
        let addr = loadAddr() ?? "127.0.0.1:19680"
        api.configure(addr: addr, token: token)

        // wait for backend to be ready
        for i in 0..<15 {
            if await api.healthCheck() {
                backendRunning = true
                backendStarting = false
                statusMessage = nil
                await refreshSessions()
                startPolling()
                return
            }
            statusMessage = "Waiting for backend... (\(i + 1)/15)"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        backendStarting = false
        backendRunning = false
        errorMessage = "Backend failed to start on \(addr)"
        statusMessage = "Backend failed"
    }

    private func findCBSPaths() -> [String] {
        let home = NSHomeDirectory()
        var paths: [String] = []

        // 1. In the .app bundle's parent directory
        if let bundleURL = Bundle.main.bundleURL
            .deletingLastPathComponent()  // CBSM.app/Contents -> CBSM.app
            .deletingLastPathComponent()  // CBSM.app -> parent dir
            .appendingPathComponent("cbsm")
            .absoluteURL.path.removingPercentEncoding {
            paths.append(bundleURL)
        }

        // 2. In .local/bin
        paths.append(home + "/.local/bin/cbsm")

        // 3. In Projects/cbsm/bin
        paths.append(home + "/Projects/cbsm/bin/cbsm")

        // 4. Check Go path / GOPATH
        paths.append(home + "/go/bin/cbsm")

        return paths
    }

    // MARK: - Session Operations

    func refreshSessions() async {
        guard backendRunning else { return }

        do {
            let previousSelection = selectedSession?.id
            let (_, summaries) = try await api.listSessions()
            sessions = summaries

            // preserve selection across refresh
            if let prevId = previousSelection,
               let current = summaries.first(where: { $0.id == prevId }) {
                selectedSession = current
            }
        } catch {
            // don't overwrite UI state on transient errors
            if backendRunning {
                // check if backend died
                if await !api.healthCheck() {
                    backendRunning = false
                    statusMessage = "Backend disconnected"
                }
            }
        }
    }

    func selectSession(_ session: SessionSummary) {
        selectedSession = session
    }

    func createSession(projectDir: String, name: String?, cbcSessionID: String?) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let _ = try await api.createSession(
                projectDir: projectDir,
                name: name,
                cbcSessionID: cbcSessionID
            )
            await refreshSessions()
            // auto-select the new session so terminal connects immediately
            if let created = sessions.first(where: { $0.projectDir == projectDir && $0.name == (name ?? "") }) {
                selectedSession = created
            } else if let first = sessions.first {
                selectedSession = first
            }
            showNewSessionSheet = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func quickCreateSession() async {
        let home = NSHomeDirectory()
        let count = sessions.count + 1
        let name = "Session \(count)"
        await createSession(projectDir: home, name: name, cbcSessionID: nil)
    }

    func deleteSession(id: String) async {
        do {
            try await api.deleteSession(id: id)
            if selectedSession?.id == id {
                selectedSession = nil
            }
            await refreshSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSession(id: String, name: String) async {
        do {
            _ = try await api.renameSession(id: id, name: name)
            await refreshSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreAll() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let count = try await api.restoreAll()
            statusMessage = "Restored \(count) sessions"
            await refreshSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attachToSession(_ session: SessionSummary) async { /* terminal handles this */ }

    // Get session project directory for terminal spawning
    func getSessionProjectDir(id: String) -> String? {
        // sessions are already loaded, find the project dir from summaries
        return sessions.first(where: { $0.id == id })?.projectDir
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSessions()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Persistence

    private func saveToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: "cbsm_token")
    }

    private func loadToken() -> String? {
        UserDefaults.standard.string(forKey: "cbsm_token")
    }

    private func saveAddr(_ addr: String) {
        UserDefaults.standard.set(addr, forKey: "cbsm_addr")
    }

    private func loadAddr() -> String? {
        UserDefaults.standard.string(forKey: "cbsm_addr")
    }
}
