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
        SessionRowContent(session: session, manager: manager)
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

/// Small badge showing which agent a session runs. When a manager exists it
/// observes it so the badge updates live when an agent is detected inside a
/// bash session (same fix as SessionStatusView).
private struct AgentBadge: View {
    let manager: TerminalManager?
    let configuredAgent: AgentType

    var body: some View {
        if let mgr = manager {
            AgentBadgeObserved(manager: mgr, fallback: configuredAgent)
        } else {
            AgentBadgeContent(agent: configuredAgent)
        }
    }
}

private struct AgentBadgeObserved: View {
    @ObservedObject var manager: TerminalManager
    let fallback: AgentType

    var body: some View {
        AgentBadgeContent(agent: manager.detectedAgentType ?? fallback)
    }
}

private struct AgentBadgeContent: View {
    let agent: AgentType

    private var color: Color {
        switch agent {
        case .codebuddy: return .blue
        case .claude: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: agent.symbolName)
                .font(.system(size: 8))
            Text(agent.displayName)
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
        .help("Agent: \(agent.displayName)")
    }
}

/// Live idle/running status. Owns the @ObservedObject so it re-renders when
/// the manager's @Published state changes — the content row passes the manager
/// as a plain value and must NOT key on it (identical `.id()` across rows
/// breaks LazyVStack, hiding rows).
private struct SessionStatusView: View {
    @ObservedObject var manager: TerminalManager

    var body: some View {
        if manager.processRunning {
            HStack(spacing: 4) {
                Circle()
                    .fill(manager.isIdle ? Color.secondary : Color.green)
                    .frame(width: 5, height: 5)
                Text(manager.isIdle ? "idle" : "running")
                    .font(.system(size: 10))
                    .foregroundColor(manager.isIdle ? .secondary : .green)
            }
        }
    }
}

/// Conversation context usage percentage for an agent session, refreshed
/// periodically from the backend.
private struct ContextUsageView: View {
    let agent: AgentType
    /// Known agent session ID, or nil to resolve via find-session from the
    /// project directory (used for bash sessions that launched an agent).
    let cbcSessionID: String?
    let projectDir: String
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var percent: Int?
    @State private var credit: Double?

    var body: some View {
        HStack(spacing: 4) {
            if percent != nil || credit != nil {
                Image(systemName: "text.page")
                    .font(.system(size: 9))
                if let percent {
                    Text("上下文 \(percent)%")
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
                if let credit {
                    Text("· ¥\(String(format: "%.2f", credit))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
            } else {
                // Placeholder keeps the view mounted so .task runs; an empty
                // body would make SwiftUI skip mounting and never fetch.
                Text("  ")
            }
        }
        .foregroundColor((percent ?? 0) >= 80 ? .orange : .secondary)
        .task {
            while !Task.isCancelled {
                var cbc = cbcSessionID
                if cbc == nil {
                    cbc = await viewModel.findAgentSession(agent: agent, projectDir: projectDir)
                }
                if let cbc, let usage = await viewModel.agentContextUsage(agent: agent, cbcSessionID: cbc, projectDir: projectDir) {
                    percent = usage.percent
                    credit = usage.credit
                }
                if percent != nil || credit != nil {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                } else {
                    // Backend may not be ready yet on launch; retry quickly.
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
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
                HStack(spacing: 6) {
                    Text(session.name)
                        .font(.system(size: 13))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                    // Current agent badge: observes the manager so it flips
                    // live when an agent is detected inside the shell.
                    AgentBadge(
                        manager: manager,
                        configuredAgent: viewModel.configuredAgentType(for: session.id)
                    )
                }

                // Conversation context usage, under the session name.
                // Show for agent sessions (known cbc) and for bash sessions
                // that have launched an agent (resolved via find-session).
                // The agent type must match the cbc (a backend cbc may hold a
                // claude session ID while the backend agent_type is still the
                // default), so use the actual agent for the session.
                let currentAgent = viewModel.currentAgentType(for: session.id)
                if let cbc = session.cbcSessionID, !cbc.isEmpty {
                    ContextUsageView(agent: currentAgent, cbcSessionID: cbc, projectDir: session.projectDir)
                } else if let mgr = manager, let detected = mgr.detectedAgentType {
                    ContextUsageView(agent: detected, cbcSessionID: nil, projectDir: session.projectDir)
                }

                // Status line (observed live by SessionStatusView)
                if let mgr = manager {
                    SessionStatusView(manager: mgr)
                }

                HStack(spacing: 4) {
                    if viewModel.isSessionActive(session.id) {
                        // formattedElapsed is computed on read; TimelineView
                        // re-evaluates every second so the clock ticks live.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack(spacing: 2) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                Text(manager?.formattedElapsed ?? "")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(.orange)
                        }
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
