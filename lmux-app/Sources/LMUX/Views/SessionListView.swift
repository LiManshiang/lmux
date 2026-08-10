import SwiftUI
import LMUXCore

struct SessionListView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Session search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search sessions", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.visibleSessions) { session in
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
                                    confirmDelete(session)
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            if viewModel.visibleSessions.isEmpty && !viewModel.isLoading {
                VStack {
                    Text(viewModel.searchText.isEmpty ? "No sessions" : "No matching sessions")
                        .foregroundColor(.secondary)
                    if viewModel.searchText.isEmpty {
                        Button("Restore from History") {
                            Task { await viewModel.restoreAll() }
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .onChange(of: viewModel.searchFocusToken) { _ in
            searchFocused = true
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

    /// Confirm before deleting a session (destructive, removes history).
    private func confirmDelete(_ session: SessionSummary) {
        let alert = NSAlert()
        alert.messageText = "Delete Session"
        alert.informativeText = "Delete '\(session.name)'? This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await viewModel.deleteSession(id: session.id) }
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

/// Small badge showing which agent a session runs. Always mounted so it can
/// observe the manager: when an agent is detected inside a bash session the
/// badge appears live instead of waiting for a list rebuild.
private struct AgentBadge: View {
    let manager: TerminalManager?
    let configuredAgent: AgentType
    /// Static condition (cbc present or restore launchMode==agent); the
    /// live-detected agent is observed separately.
    let isAgentSession: Bool

    var body: some View {
        if let mgr = manager {
            AgentBadgeObserved(manager: mgr, fallback: configuredAgent, showIf: isAgentSession)
        } else if isAgentSession {
            AgentBadgeContent(agent: configuredAgent)
        }
    }
}

private struct AgentBadgeObserved: View {
    @ObservedObject var manager: TerminalManager
    let fallback: AgentType
    let showIf: Bool

    var body: some View {
        if manager.detectedAgentType != nil || showIf {
            AgentBadgeContent(agent: manager.detectedAgentType ?? fallback)
        }
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
                    // Agent badge, always mounted so it observes the manager:
                    // appears live when an agent is detected in the shell,
                    // hidden for plain bash sessions.
                    AgentBadge(
                        manager: manager,
                        configuredAgent: viewModel.configuredAgentType(for: session.id),
                        isAgentSession: (session.cbcSessionID != nil && !session.cbcSessionID!.isEmpty)
                            || viewModel.isAgentMode(for: session.id)
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
