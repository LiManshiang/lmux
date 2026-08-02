import Foundation
import AppKit
import Darwin
import SwiftTerm

@MainActor
class TerminalManager: ObservableObject {
    @Published var isConnected: Bool = false
    var terminalView: LocalProcessTerminalView?

    func connect(projectDir: String, cbcSessionID: String? = nil) {
        disconnect()

        let cbcPath = findCodeBuddyPath()
        var args = ["--permission-mode", "auto", "-y"]
        if let id = cbcSessionID, !id.isEmpty { args.append(contentsOf: ["--session-id", id]) }

        let home = NSHomeDirectory()
        var pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        // Build PATH safely: split existing, prepend new entries, join with ":"
        var pathComponents = pathEnv.components(separatedBy: ":")
        let cbcDir = URL(fileURLWithPath: cbcPath).deletingLastPathComponent().path
        for p in [cbcDir, "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] {
            if !pathComponents.contains(p) {
                pathComponents.insert(p, at: 0)
            }
        }
        pathEnv = pathComponents.joined(separator: ":")

        // Inherit parent environment (auth tokens, API keys, etc.), override only what's needed
        var parentEnv = ProcessInfo.processInfo.environment
        parentEnv["TERM"] = "xterm-256color"
        parentEnv["LANG"] = "en_US.UTF-8"
        parentEnv["PATH"] = pathEnv
        parentEnv["HOME"] = home
        parentEnv["NVM_DIR"] = "\(home)/.nvm"

        // Build env list safely: join with "=" instead of string interpolation
        let envList = parentEnv.map { key, value in "\(key)=\(value)" }

        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
        view.nativeForegroundColor = NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
        view.selectedTextBackgroundColor = NSColor(red: 0.3, green: 0.3, blue: 0.4, alpha: 0.6)
        view.startProcess(executable: cbcPath, args: args, environment: envList, currentDirectory: projectDir)

        view.processDelegate = Delegate { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = false
            }
        }

        self.terminalView = view
        self.isConnected = true
    }

    func disconnect() {
        terminalView?.process.terminate()
        terminalView = nil
        isConnected = false
    }

    private nonisolated func findCodeBuddyPath() -> String {
        // Check well-known paths without spawning a process (avoids main thread blocking)
        let candidates = [
            "\(NSHomeDirectory())/.nvm/versions/node/*/bin/codebuddy-code",
            "/opt/homebrew/bin/codebuddy-code",
            "/usr/local/bin/codebuddy-code",
            "\(NSHomeDirectory())/.local/bin/codebuddy-code",
        ]
        for pattern in candidates {
            if pattern.contains("*") {
                if let match = try? TerminalManager.glob(pattern).first {
                    return match
                }
            } else if FileManager.default.isExecutableFile(atPath: pattern) {
                return pattern
            }
        }

        // Fallback: run `which`
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["codebuddy-code"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        } catch {}
        return "/opt/homebrew/bin/codebuddy-code"
    }

    private static nonisolated func glob(_ pattern: String) throws -> [String] {
        var globResult = glob_t()
        defer { globfree(&globResult) }
        let flags = GLOB_TILDE | GLOB_BRACE | GLOB_NOSORT
        let result = pattern.withCString { Darwin.glob($0, flags, nil, &globResult) }
        guard result == 0 else { return [] }
        return (0..<Int(globResult.gl_matchc)).compactMap { i in
            globResult.gl_pathv[i].flatMap { String(cString: $0) }
        }
    }
}

private class Delegate: NSObject, LocalProcessTerminalViewDelegate {
    let onExit: () -> Void
    init(onExit: @escaping () -> Void) { self.onExit = onExit }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) { onExit() }
}
