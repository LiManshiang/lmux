import SwiftUI

struct SessionDetailView: View {
    let session: SessionSummary
    @EnvironmentObject var viewModel: ContentViewModel
    @StateObject private var terminalManager = TerminalManager()
    @State private var didConnect = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        Label(session.projectDir, systemImage: "folder")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                if terminalManager.isConnected {
                    Button(action: { terminalManager.disconnect() }) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            TerminalView(manager: terminalManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            print("[CBSM] SessionDetailView.onAppear for \(session.name) (id=\(session.id))")
            guard !didConnect else { return }
            didConnect = true
            connectTerminal()
        }
        .onDisappear {
            terminalManager.disconnect()
        }
        .onReceive(viewModel.$selectedSession) { newSession in
            if newSession?.id != session.id {
                terminalManager.disconnect()
            }
        }
    }

    private func connectTerminal() {
        guard let dir = viewModel.getSessionProjectDir(id: session.id) else { return }
        terminalManager.connect(projectDir: dir, cbcSessionID: session.cbcSessionID)
    }
}
