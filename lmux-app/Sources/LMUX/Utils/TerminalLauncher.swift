import AppKit
import LMUXCore

/// Launches an agent conversation outside lmux — in Terminal.app with a
/// fresh `agent --resume <id>` so the user keeps working in their own shell.
enum TerminalLauncher {
    /// Shell command an agent runs to resume a conversation in its cwd.
    static func resumeCommand(agentType: AgentType, sessionID: String, cwd: String) -> String {
        let cwdEsc = cwd.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let flags = agentType.resumeArgs(sessionID: sessionID).joined(separator: " ")
        return "cd \"\(cwdEsc)\" && \(agentType.executableName) \(flags)"
    }

    /// Open Terminal.app and run the resume command in a new window/tab.
    @discardableResult
    static func openInTerminal(agentType: AgentType, sessionID: String, cwd: String) -> Bool {
        let command = resumeCommand(agentType: agentType, sessionID: sessionID, cwd: cwd)
        // Escape for AppleScript string interpolation.
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to activate\n" +
                     "tell application \"Terminal\" to do script \"\(escaped)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            return true
        } catch {
            // Used to be try?: a failure looked like nothing happened at all.
            return false
        }
    }
}
