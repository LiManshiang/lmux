import Foundation
import AppKit
import SwiftTerm

@MainActor
class TerminalManager: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var processRunning: Bool = false

    /// Called on main actor when the codebuddy-code process exits.
    var onProcessExit: (() -> Void)?
    /// Called on main actor when the codebuddy-code process starts.
    var onProcessStart: (() -> Void)?

    /// The SwiftTerm LocalProcessTerminalView (NSView with built-in PTY)
    private(set) var terminalView: LocalProcessTerminalView?

    private var currentSessionID: String?

    /// Connect by spawning codebuddy-code directly via SwiftTerm's forkpty.
    func connect(sessionID: String, projectDir: String, cbcSessionID: String?) {
        disconnect()

        currentSessionID = sessionID

        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
        view.nativeForegroundColor = NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)

        // Build command
        let cbcPath = findCodeBuddyPath()
        var args = ["--permission-mode", "auto", "-y"]
        if let id = cbcSessionID, !id.isEmpty {
            args.append(contentsOf: ["--session-id", id])
        }

        // Build environment
        let home = NSHomeDirectory()
        var parentEnv = ProcessInfo.processInfo.environment
        parentEnv["TERM"] = "xterm-256color"
        parentEnv["LANG"] = "en_US.UTF-8"
        parentEnv["HOME"] = home

        // Fix PATH
        var pathEnv = parentEnv["PATH"] ?? "/usr/bin:/bin"
        for p in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] {
            if !pathEnv.contains(p) { pathEnv = "\(p):\(pathEnv)" }
        }
        let cbcDir = URL(fileURLWithPath: cbcPath).deletingLastPathComponent().path
        if !pathEnv.contains(cbcDir) { pathEnv = "\(cbcDir):\(pathEnv)" }
        parentEnv["PATH"] = pathEnv

        let envList = parentEnv.map { "\($0.key)=\($0.value)" }

        // Start process
        view.startProcess(executable: cbcPath, args: args, environment: envList, currentDirectory: projectDir)

        // Track process exit
        view.processDelegate = Delegate { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = false
                self?.processRunning = false
                self?.onProcessExit?()
            }
        }

        self.terminalView = view
        isConnected = true
        processRunning = true
        onProcessStart?()
    }

    func disconnect() {
        terminalView?.process.terminate()
        terminalView = nil
        currentSessionID = nil
        isConnected = false
        processRunning = false
    }

    /// Detach without killing: disconnect UI but keep process running.
    /// LocalProcessTerminalView's process continues because we don't call terminate().
    func detach() {
        isConnected = false
        // Keep terminalView alive so process keeps running
    }

    /// Re-attach: terminalView and process are still alive, just mark connected.
    func reattach() {
        guard terminalView != nil else { return }
        isConnected = true
    }

    private func findCodeBuddyPath() -> String {
        // 1. Search PATH first
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        for dir in pathDirs {
            let p = "\(dir)/codebuddy-code"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        // 2. Try common fixed paths
        let candidates = [
            "/opt/homebrew/bin/codebuddy-code",
            "/usr/local/bin/codebuddy-code",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        // 3. Search nvm installations across mounted volumes
        let home = NSHomeDirectory()
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for vol in volumes where vol != "Macintosh HD" && !vol.hasPrefix(".") {
            let nvmBase = "/Volumes/\(vol)/OpenSource/nvm/versions/node"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
                for entry in entries {
                    let p = "\(nvmBase)/\(entry)/bin/codebuddy-code"
                    if FileManager.default.isExecutableFile(atPath: p) { return p }
                }
            }
        }

        // 4. Check NVM_DIR from environment
        let env = ProcessInfo.processInfo.environment
        if let nvmDir = env["NVM_DIR"] {
            let p = "\(nvmDir)/codebuddy-code"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        return "/opt/homebrew/bin/codebuddy-code"
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
