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

                // Main terminal — always at a non-conditional position.
                // The split pane is an overlay so it doesn't create conditional
                // view branches around the PTYTerminalView. This prevents
                // NSView recreation when observed state changes.
                PTYTerminalView(manager: mgr)
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

            if let cbc, !cbc.isEmpty {
                // Resume existing agent session
                mgr.connect(
                    sessionID: id,
                    projectDir: dir,
                    cbcSessionID: cbc,
                    agentType: session?.agentType ?? .codebuddy
                )
            } else {
                // New session: start with bash terminal
                mgr.connectBash(sessionID: id, projectDir: dir, agentType: session?.agentType ?? .codebuddy)
            }
        } else if !mgr.isConnected {
            mgr.reattach()
        }

        viewModel.connectedSessionId = id
    }
}
