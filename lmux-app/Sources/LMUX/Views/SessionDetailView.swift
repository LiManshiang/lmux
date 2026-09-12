import SwiftUI
import LMUXCore

/// Header subtitle: the session process's live working directory (updates as
/// the agent/shell `cd`s), falling back to the configured project dir. Owns
/// the @ObservedObject so it re-renders on poll updates.
private struct SessionCwdLabel: View {
    @ObservedObject var manager: TerminalManager
    let projectDir: String

    var body: some View {
        Text(manager.currentWorkingDirectory ?? projectDir)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Working directory of this session's process")
    }
}

struct SessionDetailView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var showSplitPane = false
    @State private var terminalHeight: CGFloat = 200
    /// The usage panel on the right. Persisted so it stays where the user左 it.
    @AppStorage("showSessionInspector") private var showInspector = false

    /// When set, this view is hosted in its own window for one specific
    /// session (parallel workspace). It ignores the main window's selection.
    private let pinnedSession: SessionSummary?

    init() {
        self.pinnedSession = nil
    }

    init(pinnedSession: SessionSummary) {
        self.pinnedSession = pinnedSession
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = pinnedSession ?? viewModel.selectedSession {
                let sid = session.id
                let mgr = viewModel.terminalManager(for: sid)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name)
                            .font(.system(size: 13, weight: .semibold))
                            // A long name used to wrap and push the split/stop
                            // buttons out of the header.
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // Live working directory when the process is running
                        // (it can `cd` away from the configured projectDir);
                        // falls back to the configured project dir.
                        SessionCwdLabel(manager: mgr, projectDir: session.projectDir)
                    }
                    Spacer()

                    // Split pane toggle
                    if mgr.processRunning {
                        Button(action: {
                            showSplitPane.toggle()
                            if showSplitPane {
                                let splitMgr = viewModel.splitTerminalManager(for: sid)
                                if splitMgr.backend == nil {
                                    // Start the split bash in the session's live
                                    // working directory (the agent may have cd'd
                                    // somewhere), falling back to projectDir.
                                    let cwd = mgr.currentWorkingDirectory ?? session.projectDir
                                    splitMgr.connectBash(sessionID: sid, projectDir: cwd, agentType: session.agentType)
                                }
                            }
                        }) {
                            Image(systemName: showSplitPane ? "rectangle.split.1x2.fill" : "rectangle.split.1x2")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .help(showSplitPane ? "Close Terminal" : "Open Terminal")
                        .accessibilityLabel(showSplitPane ? "Close terminal" : "Open terminal")

                        Button(action: {
                            confirmStop(session: session)
                        }) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Stop")
                        .accessibilityLabel("Stop session")

                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                showInspector.toggle()
                            }
                        } label: {
                            Image(systemName: "sidebar.right")
                                .font(.system(size: 13))
                                .foregroundColor(showInspector ? .accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(showInspector ? "Hide usage panel" : "Show usage panel")
                        .accessibilityLabel("Toggle usage panel")
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
                    .overlay {
                        // "Starting / resuming…" hint while the agent boots
                        // (resume parses the full conversation history).
                        if mgr.isConnecting && !mgr.processRunning && mgr.connectErrorMessage == nil {
                            VStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(connectingLabel(session))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.92))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.secondary.opacity(0.25))
                            )
                        }
                    }
                    .overlay(alignment: .trailing) {
                        // Overlay rather than a side-by-side HStack: a conditional
                        // branch around PTYTerminalView would let SwiftUI recreate
                        // the terminal's NSView (see the note above).
                        if showInspector {
                            HStack(spacing: 0) {
                                Divider()
                                SessionInspectorView(session: session, manager: mgr)
                                    .frame(width: 240)
                                    .background(.bar)
                            }
                            .transition(.move(edge: .trailing))
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
            if let id = pinnedSession?.id ?? viewModel.selectedSession?.id {
                connectToSession(id: id)
            }
        }
        .onChange(of: viewModel.selectedSession?.id) { newID in
            // A standalone (pinned) window owns its session; the main window's
            // selection must not hijack it.
            guard pinnedSession == nil else { return }
            showSplitPane = false
            guard let id = newID else { return }
            connectToSession(id: id)
        }
    }

    private func connectToSession(id: String) {
        let mgr = viewModel.terminalManager(for: id)

        if mgr.backend == nil {
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
                    // Repair conversations whose recorded cwd no longer matches
                    // this session's project dir (history from another Mac /
                    // username) — the CLI matches by that cwd, so without this
                    // the resume would come up empty.
                    await viewModel.api.localizeSessionCwd(sessionID: id)
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

    private func connectingLabel(_ session: SessionSummary) -> String {
        guard let cbc = session.cbcSessionID, !cbc.isEmpty else {
            return "Starting terminal…"
        }
        return "Starting \(session.agentType.displayName) — resuming conversation…"
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
