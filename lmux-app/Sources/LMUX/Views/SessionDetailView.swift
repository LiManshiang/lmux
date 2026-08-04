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
                            Text(showSplitPane ? "Close Terminal" : "Terminal").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .help("Toggle bottom split pane")

                        Button(action: {
                            viewModel.killSession(id: session.id)
                        }) {
                            Text("Stop").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                // Main terminal — fills available space.
                // The split-pane area below has a FIXED outer frame height that
                // never changes when toggling visibility, so the main terminal
                // never resizes and no SIGWINCH is sent to the agent.
                PTYTerminalView(manager: mgr)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Split pane — always present, outer frame height fixed.
                // Visibility is controlled by inner content heights (0 or actual).
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: showSplitPane ? dividerHeight : 0)
                        .gesture(showSplitPane ? DragGesture().onChanged { value in
                            let newHeight = terminalHeight - value.translation.height
                            terminalHeight = max(80, min(500, newHeight))
                        } : nil)
                        .onHover { inside in
                            if inside && showSplitPane { NSCursor.resizeUpDown.push() }
                            else { NSCursor.pop() }
                        }

                    PTYTerminalView(manager: viewModel.splitTerminalManager(for: sid))
                        .frame(height: showSplitPane ? terminalHeight : 0)
                        .clipped()
                }
                .frame(height: terminalHeight + dividerHeight)
            }
        }
        .onAppear {
            showSplitPane = false
            // Only connect if not already managing a terminal for this session.
            // Prevents session restarts during polling-triggered view updates.
            if let id = viewModel.selectedSession?.id,
               viewModel.connectedSessionId != id {
                connectToSession(id: id)
            }
        }
        .onChange(of: viewModel.selectedSession?.id) { newID in
            showSplitPane = false
            guard let id = newID else { return }
            // Skip if already connected to prevent unnecessary session restarts
            guard viewModel.connectedSessionId != id else { return }
            connectToSession(id: id)
        }
    }

    private func connectToSession(id: String) {
        let mgr = viewModel.terminalManager(for: id)

        if mgr.terminalView == nil {
            let session = viewModel.sessions.first { $0.id == id }
            let dir = session?.projectDir ?? NSHomeDirectory()
            let cbc = session?.cbcSessionID
            let agent = session?.agentType ?? .codebuddy

            // Check restore entry to determine if this session was previously running an agent
            let restoreEntry = SessionRestore.loadAll().first { $0.sessionID == id }
            let hasCbcID = cbc != nil && !cbc!.isEmpty

            if hasCbcID {
                // Resume with known session ID (full history restore)
                mgr.connect(
                    sessionID: id,
                    projectDir: dir,
                    cbcSessionID: cbc,
                    agentType: agent
                )
            } else {
                // New session or previously bash-only: start with bash terminal
                mgr.connectBash(sessionID: id, projectDir: dir, agentType: agent)
            }
        } else if !mgr.isConnected {
            mgr.reattach()
        }

        viewModel.connectedSessionId = id
    }
}

private let dividerHeight: CGFloat = 4
