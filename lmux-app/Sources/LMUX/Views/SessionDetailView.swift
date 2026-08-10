import SwiftUI

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
                            viewModel.killSession(id: session.id)
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

            // A session ID is tied to its agent: the backend stores the
            // codebuddy conversation ID, which must never be passed to claude.
            let effectiveCBC: String?
            if agent == .codebuddy {
                effectiveCBC = (cbc != nil && !cbc!.isEmpty) ? cbc : restoreCBC
            } else {
                effectiveCBC = restoreCBC
            }

            if agent == .codebuddy {
                if let effectiveCBC, !effectiveCBC.isEmpty {
                    // Explicit session ID (Resume, or agent mode detected earlier):
                    // launch the agent and resume that conversation. If the ID is
                    // stale/invalid, fall back to the directory's recent session.
                    Task {
                        if await viewModel.isCodebuddySessionValid(effectiveCBC) {
                            mgr.connect(
                                sessionID: id,
                                projectDir: dir,
                                cbcSessionID: effectiveCBC,
                                agentType: agent
                            )
                        } else if let found = await viewModel.findCodebuddySession(projectDir: dir) {
                            mgr.connect(
                                sessionID: id,
                                projectDir: dir,
                                cbcSessionID: found,
                                agentType: agent
                            )
                        } else {
                            mgr.connectBash(sessionID: id, projectDir: dir, agentType: agent)
                        }
                    }
                } else if restoreEntry?.launchMode == .agent || mgr.detectedAgentType != nil {
                    // This session previously launched an agent (e.g. the user
                    // started codebuddy inside the shell). Resolve the current
                    // conversation from the directory and resume it.
                    Task {
                        if let found = await viewModel.findCodebuddySession(projectDir: dir) {
                            mgr.connect(
                                sessionID: id,
                                projectDir: dir,
                                cbcSessionID: found,
                                agentType: agent
                            )
                        } else {
                            mgr.connectBash(sessionID: id, projectDir: dir, agentType: agent)
                        }
                    }
                } else {
                    // New session without history: start a bash terminal. Agent
                    // detection will upgrade to agent mode if the user launches
                    // codebuddy/claude manually inside the shell.
                    mgr.connectBash(sessionID: id, projectDir: dir, agentType: agent)
                }
            } else {
                // claude and other non-codebuddy agents: resume the conversation
                // recorded by detection, or start a fresh one when there is none.
                Task {
                    var claudeCBC = effectiveCBC
                    if let cbc = claudeCBC, !cbc.isEmpty,
                       await viewModel.isCodebuddySessionValid(cbc) {
                        // The ID is a valid codebuddy conversation (saved from
                        // a wrongly-launched claude --resume <codebuddy-id>);
                        // never pass it to claude. Start fresh instead.
                        claudeCBC = nil
                    }
                    mgr.connect(
                        sessionID: id,
                        projectDir: dir,
                        cbcSessionID: claudeCBC,
                        agentType: agent
                    )
                }
            }
        } else if !mgr.isConnected {
            mgr.reattach()
        }

        viewModel.connectedSessionId = id
    }
}
