import Foundation
import AppKit
import SwiftTerm

@MainActor
class TerminalManager: ObservableObject {
    @Published var isConnected: Bool = false

    var terminalView: LocalProcessTerminalView?
    private var processDelegate: TerminalProcessDelegate?

    private let terminalBackground = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    private let terminalForeground = NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
    private let terminalSelection = NSColor(red: 0.3, green: 0.3, blue: 0.4, alpha: 0.6)

    func connect(projectDir: String, cbcSessionID: String? = nil) {
        disconnect()

        let bg = terminalBackground
        let fg = terminalForeground
        let sel = terminalSelection
        let dir = projectDir
        let cbcID = cbcSessionID
        let cbcPath = self.findCodeBuddyPath()
        var args: [String] = []
        if let cbcID = cbcID, !cbcID.isEmpty {
            args = ["--session-id", cbcID]
        }

        // Build PATH: inherit system PATH + add CBC's directory
        var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let cbcDir = URL(fileURLWithPath: cbcPath).deletingLastPathComponent().path
        if !path.contains(cbcDir) {
            path = "\(cbcDir):\(path)"
        }
        // also include common nvm paths
        let home = NSHomeDirectory()
        let nvmBin = "\(home)/.nvm/versions/node/*/bin"
        var extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
        for p in extraPaths where !path.contains(p) {
            path = "\(p):\(path)"
        }

        let env = ["TERM=xterm-256color", "LANG=en_US.UTF-8",
                   "HOME=\(home)",
                   "PATH=\(path)",
                   "NVM_DIR=\(home)/.nvm"]

        let view = LocalProcessTerminalView(frame: .zero)
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = bg
        view.nativeForegroundColor = fg
        view.selectedTextBackgroundColor = sel
        view.allowMouseReporting = true

        view.startProcess(
            executable: cbcPath,
            args: args,
            environment: env,
            currentDirectory: dir
        )

        let delegate = TerminalProcessDelegate { [weak self] in
            DispatchQueue.main.async { self?.isConnected = false }
        }
        view.processDelegate = delegate
        self.processDelegate = delegate

        self.terminalView = view
        self.isConnected = true
    }

    func disconnect() {
        if let v = terminalView {
            let bytes: [UInt8] = [0x03] // Ctrl-C to gracefully exit
            v.getTerminal().feed(byteArray: bytes)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                v.process.terminate()
            }
        }
        terminalView = nil
        isConnected = false
    }

    private func findCodeBuddyPath() -> String {
        // check which codebuddy-code
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["codebuddy-code"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}
        return "/opt/homebrew/bin/codebuddy-code"
    }
}

class TerminalProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private let onTerminate: () -> Void

    init(onTerminate: @escaping () -> Void) {
        self.onTerminate = onTerminate
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        onTerminate()
    }
}
