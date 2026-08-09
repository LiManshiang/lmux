import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var viewModel: ContentViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.sessions) { session in
                    SessionRowView(session: session)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectSession(session)
                        }
                        .contextMenu {
                            Button("Attach in Terminal") {
                                Task { await viewModel.attachToSession(session) }
                            }
                            Divider()
                            Button("Rename...") {
                                showRenameAlert(session)
                            }
                            Button("Delete", role: .destructive) {
                                Task { await viewModel.deleteSession(id: session.id) }
                            }
                        }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            if viewModel.sessions.isEmpty && !viewModel.isLoading {
                VStack {
                    Text("No sessions")
                        .foregroundColor(.secondary)
                    Button("Restore from History") {
                        Task { await viewModel.restoreAll() }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func showRenameAlert(_ session: SessionSummary) {
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a new name for this session."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = session.name
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            Task { await viewModel.renameSession(id: session.id, name: input.stringValue) }
        }
    }
}

struct SessionRowView: View {
    let session: SessionSummary
    @EnvironmentObject var viewModel: ContentViewModel

    private var manager: TerminalManager? {
        // Read-only: don't create a TerminalManager just to render a row.
        viewModel.terminalManagerIfExists(for: session.id)
    }

    var body: some View {
        if let mgr = manager {
            // Observe the manager so idle/running state updates in real time.
            SessionRowObserved(session: session, manager: mgr)
        } else {
            SessionRowStatic(session: session)
        }
    }
}

/// Row rendered when a TerminalManager exists; observes it for live status.
private struct SessionRowObserved: View {
    let session: SessionSummary
    @ObservedObject var manager: TerminalManager
    @EnvironmentObject var viewModel: ContentViewModel

    var body: some View {
        // SessionRowContent receives `manager` as a plain value, so SwiftUI's
        // structural-equality pass can skip re-evaluating its body when only
        // the manager's @Published state (isIdle/processRunning) changed.
        // Keying on that state forces the content to rebuild in real time.
        SessionRowContent(session: session, manager: manager)
            .id("\(manager.isIdle)-\(manager.processRunning)")
    }
}

/// Row rendered when no TerminalManager exists yet (nothing to observe).
private struct SessionRowStatic: View {
    let session: SessionSummary
    @EnvironmentObject var viewModel: ContentViewModel

    var body: some View {
        SessionRowContent(session: session, manager: nil)
    }
}

private struct SessionRowContent: View {
    let session: SessionSummary
    let manager: TerminalManager?
    @EnvironmentObject var viewModel: ContentViewModel

    private var isSelected: Bool {
        viewModel.selectedSession?.id == session.id
    }

    private var needsAttention: Bool {
        viewModel.needsSessionAttention(session.id)
    }

    private var statusDotColor: Color {
        if viewModel.isSessionActive(session.id) || viewModel.hasSessionCompleted(session.id) {
            return Color.green
        }
        return Color.gray
    }

    var body: some View {
        HStack(spacing: 8) {
            // Status dot with attention ring
            ZStack {
                if needsAttention {
                    Circle()
                        .stroke(Color.orange, lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .opacity(attentionPulse ? 0.3 : 1.0)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: attentionPulse)
                }
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
            }
            .frame(width: 14, height: 14)
            .onAppear { attentionPulse = needsAttention }

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.system(size: 13))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)

                // Status line
                if let mgr = manager, mgr.processRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(mgr.isIdle ? Color.secondary : Color.green)
                            .frame(width: 5, height: 5)
                        Text(mgr.isIdle ? "idle" : "running")
                            .font(.system(size: 10))
                            .foregroundColor(mgr.isIdle ? .secondary : .green)
                    }
                }

                HStack(spacing: 4) {
                    if viewModel.isSessionActive(session.id), let elapsed = manager?.formattedElapsed {
                        HStack(spacing: 2) {
                            Image(systemName: "clock")
                                .font(.system(size: 9))
                            Text(elapsed)
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.orange)
                    }

                    if let branch = session.gitBranch {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                            Text(branch)
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                    }

                    if let title = session.aiTitle {
                        Text(title)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) :
                     needsAttention ? Color.orange.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.4) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    @State private var attentionPulse = false
}
