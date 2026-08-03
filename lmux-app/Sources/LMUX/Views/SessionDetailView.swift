import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var showSplitPane = false

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
                                    splitMgr.connectBash(sessionID: sid, projectDir: session.projectDir)
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

                if showSplitPane {
                    VStack(spacing: 0) {
                        PTYTerminalView(manager: mgr)
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)

                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(height: 1)

                        PTYTerminalView(manager: viewModel.splitTerminalManager(for: sid))
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                    }
                } else {
                    PTYTerminalView(manager: mgr)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
