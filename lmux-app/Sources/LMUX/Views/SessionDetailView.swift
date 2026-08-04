import SwiftUI

struct SessionDetailView: View {
    @EnvironmentObject var viewModel: ContentViewModel

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
                    if mgr.processRunning {
                        Button(action: {
                            viewModel.killSession(id: session.id)
                        }) {
                            Text("Kill").font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                PTYTerminalView(manager: mgr)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // Handle initial session when view first appears
            if let id = viewModel.selectedSession?.id {
                connectToSession(id: id)
            }
        }
        .onChange(of: viewModel.selectedSession?.id) { newID in
            guard let id = newID else { return }
            connectToSession(id: id)
        }
    }

    private func connectToSession(id: String) {
        let mgr = viewModel.terminalManager(for: id)

        if mgr.terminalView == nil {
            let session = viewModel.sessions.first { $0.id == id }
            mgr.connect(
                sessionID: id,
                projectDir: session?.projectDir ?? NSHomeDirectory(),
                cbcSessionID: session?.cbcSessionID
            )
        } else if !mgr.isConnected {
            mgr.reattach()
        }

        viewModel.connectedSessionId = id
    }
}
