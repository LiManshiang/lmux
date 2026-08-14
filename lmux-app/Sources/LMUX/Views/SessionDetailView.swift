import SwiftUI
import LMUXCore

struct SessionDetailView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var showSplitPane = false
    @State private var terminalHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            if let session = viewModel.selectedSession {
                let sid = session.id
                let mgr = viewModel.terminalManager(for: sid)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name)
                            .font(.system(size: 13, weight: .semibold))
                        Text(session.projectDir)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()

                    // Split pane toggle
                    if mgr.processRunning {
                        Button(action: {
                            showSplitPane.toggle()
                            if showSplitPane {
                                let splitMgr = viewModel.splitTerminalManager(for: sid)
                                if splitMgr.terminalView == nil {
                                    splitMgr.connectBash(sessionID: sid, projectDir: session.projectDir, agentType: session.agentType)
                                }
                            }
                        }) {
                            Image(systemName: showSplitPane ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .help(showSplitPane ? "Close Terminal" : "Open Terminal")

                        Button(action: {
                            confirmStop(session: session)
                        }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Stop")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                // Main terminal — always at a non-conditional position.
                // The split pane is an overlay so it doesn't create conditional
                // view branches around the PTYTerminalView. This prevents
                // NSView recreation when observed state changes. Stable .id()
                // values keep SwiftUI from recreating the NSView across
                // structural changes (see K3).
                PTYTerminalView(manager: mgr)
                    .id("main-terminal-\(sid)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        // Show a connection failure in the terminal area
                        // instead of a blank screen (e.g. agent binary missing).
                        if let err = mgr.connectErrorMessage, !mgr.processRunning {
                            ConnectionErrorView(message: err) {
                                mgr.clearConnectError()
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if showSplitPane {
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.3))
                                    .frame(height: 4)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                let newHeight = terminalHeight - value.translation.height
                                                terminalHeight = max(80, min(500, newHeight))
                                            }
                                    )

                                PTYTerminalView(manager: viewModel.splitTerminalManager(for: sid))
                                    .id("split-terminal-\(sid)")
                                    .frame(height: terminalHeight)
                            }
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
            }
        }
        .onAppear {
            showSplitPane = false
            if let id = viewModel.selectedSession?.id {
                connectToSession(id: id)
            }
        }
        .onChange(of: viewModel.selectedSession?.id) { newID in
            showSplitPane = false
            guard let id = newID else { return }
            connectToSession(id: id)
        }
    }

    private func connectToSession(id: String) {
        let mgr = viewModel.terminalManager(for: id)

        if mgr.terminalView == nil {
            let session = viewModel.sessions.first { $0.id == id }
            let dir = session?.projectDir ?? NSHomeDirectory()
            let cbc = session?.cbcSessionID

            // Try backend first, then restore.json (agent detection might have captured it).
            let restoreEntry = SessionRestore.loadAll().first { $0.sessionID == id }
            let restoreCBC = restoreEntry?.cbcSessionID

            // Prefer the agent type recorded by detection (e.g. claude when the
            // user launched claude inside the shell) over the session's default.
            let agent = restoreEntry?.agentType ?? session?.agentType ?? .codebuddy
            let provider = agent.provider

            // A session ID is tied to its agent; the provider validates it and
            // decides whether to look up the agent's history (e.g. a backend
            // codebuddy ID is discarded for claude).
            let effectiveCBC: String?
            effectiveCBC = (cbc != nil && !cbc!.isEmpty) ? cbc : restoreCBC
            let isAgentSession = restoreEntry?.launchMode == .agent || mgr.detectedAgentType != nil || (effectiveCBC != nil && !effectiveCBC!.isEmpty)

            Task {
                let decision = await provider.resolveSession(
                    cbcSessionID: effectiveCBC,
                    projectDir: dir,
                    allowHistoryLookup: isAgentSession,
                    service: viewModel.api
                )
                switch decision {
                case .resume(let sessionID):
                    mgr.connect(
                        sessionID: id,
                        projectDir: dir,
                        cbcSessionID: sessionID,
                        agentType: agent
                    )
                case .fresh:
                    mgr.connect(
                        sessionID: id,
                        projectDir: dir,
                        cbcSessionID: nil,
                        agentType: agent
                    )
                case .bash:
                    // New session without history: start a bash terminal. Agent
                    // detection will upgrade to agent mode if the user launches
                    // an agent manually inside the shell.
                    mgr.connectBash(sessionID: id, projectDir: dir, agentType: agent)
                }
            }
        } else if !mgr.isConnected {
            mgr.reattach()
        }

        viewModel.connectedSessionId = id
    }

    /// Confirm before stopping a session's running agent process.
    private func confirmStop(session: SessionSummary) {
        let alert = NSAlert()
        alert.messageText = "Stop Session"
        alert.informativeText = "Stop the running process in '\(session.name)'? You can restart it later."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            viewModel.killSession(id: session.id)
        }
    }
}

/// Shown in the terminal area when a session fails to connect (agent binary
/// missing, launch failure, etc.) instead of a blank screen.
private struct ConnectionErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundColor(.orange)
            Text("Connection Failed")
                .font(.headline)
            Text(message)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
            Button("Dismiss") { onDismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
    }
}
