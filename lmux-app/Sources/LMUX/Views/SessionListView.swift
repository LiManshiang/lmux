import SwiftUI
import LMUXCore

struct SessionListView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var pinnedCollapsed = false
    @State private var unboundCollapsed = false
    @State private var collapseState: [AgentType: Bool] = [:]

    private func collapseBinding(for agent: AgentType) -> Binding<Bool> {
        Binding(
            get: { collapseState[agent] ?? false },
            set: { collapseState[agent] = $0 }
        )
    }
    private func sessionRow(_ session: SessionSummary) -> some View {
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
                Button("Open in New Window") {
                    SessionWindowController.shared.open(session: session, viewModel: viewModel)
                }
                .disabled(viewModel.selectedSession?.id == session.id)
                .help("Run this session in its own terminal window")
                Divider()
                Button(session.pinned ? "Unpin (取消置顶)" : "Pin to Top (置顶)") {
                    Task { await viewModel.togglePin(session: session) }
                }
                Divider()
                Button("Export Session…") {
                    viewModel.promptExportSession(session)
                }
                Button("Import Session…") {
                    viewModel.promptImportSession()
                }
                Divider()
                Button("Edit Session…") {
                    viewModel.promptEditSession(session)
                }
                .disabled(session.status == .running)
                Button("Rename...") {
                    showRenameAlert(session)
                }
                Button("Delete", role: .destructive) {
                    confirmDelete(session)
                }
            }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let pinned = viewModel.visibleSessions.filter { $0.pinned }
                let others = viewModel.visibleSessions.filter { !$0.pinned }

                // Pinned (starred) sessions at the very top.
                if !pinned.isEmpty {
                    GroupHeader(title: "置顶", count: pinned.count, isCollapsed: $pinnedCollapsed)
                    if !pinnedCollapsed {
                        ForEach(pinned) { session in
                            sessionRow(session)
                        }
                    }
                }

                // Regular sessions grouped by agent type, each collapsible.
                // Only sessions actually bound to an agent conversation go
                // into an agent group; a freshly created (or plain bash)
                // session with no conversation stays in the "未启动" group.
                // The grouping is pre-computed once (single restore.json
                // read) instead of per-session lookups in the view body.
                let grouping = viewModel.groupSessions(others)
                let unbound = grouping.unbound

                if !unbound.isEmpty {
                    GroupHeader(title: "未启动", count: unbound.count, isCollapsed: $unboundCollapsed)
                    if !unboundCollapsed {
                        ForEach(unbound) { session in
                            sessionRow(session)
                        }
                    }
                }

                ForEach(grouping.agentOrder, id: \.self) { agent in
                    let rows = grouping.bound[agent] ?? []
                    if !rows.isEmpty {
                        GroupHeader(title: agent.displayName, count: rows.count, isCollapsed: collapseBinding(for: agent))
                        if !(collapseState[agent] ?? false) {
                            ForEach(rows) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .overlay {
            // Empty state only once the backend is actually up and the first
            // load finished — showing it earlier makes it flash over the list
            // during launch.
            if viewModel.visibleSessions.isEmpty && viewModel.backendRunning && !viewModel.isLoading {
                VStack(spacing: 6) {
                    Text(viewModel.searchText.isEmpty ? "No sessions" : "No matching sessions")
                        .foregroundColor(.secondary)
                    if viewModel.searchText.isEmpty {
                        // Agent conversations (raw JSONL that was never opened
                        // in lmux) are browsed and resumed from the Agent tab.
                        Text("Browse all agent conversations from the Agent tab")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
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

/// A collapsible group header for the session list (pinned / agent groups).
private struct GroupHeader: View {
    let title: String
    let count: Int
    @Binding var isCollapsed: Bool

    var body: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("\(count)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
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
        // Re-evaluate when a TerminalManager is created for any session: a
        // row may have first rendered without one (static), and a manager
        // appearing later must flip the row to the observed variant so the
        // context-usage line shows up without waiting for another viewModel
        // change (e.g. switching sessions → refreshSessions).
        let _ = viewModel.managerGeneration
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
                if let cpu = manager.cpuPercent, cpu > 1 {
                    Text("CPU \(cpu, specifier: "%.0f")%")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundColor(cpu > 80 ? .orange : .secondary)
                }
                if let mem = manager.memoryMB, mem > 1 {
                    Text("\(Int(mem))MB")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Conversation context usage percentage for an agent session, refreshed
/// periodically from the backend.
private struct ContextUsageView: View {
    let sessionID: String
    let agent: AgentType
    /// Known agent session ID, or nil to resolve via find-session from the
    /// project directory (used for bash sessions that launched an agent).
    let cbcSessionID: String?
    let projectDir: String
    @EnvironmentObject var viewModel: ContentViewModel
    /// Starts at 0 so an agent-bound session always shows a number — never a
    /// blank placeholder — while the first context query is in flight.
    @State private var percent = 0
    @State private var model: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.page")
                .font(.system(size: 9))
            Text("上下文 \(percent)%")
                .font(.system(size: 10))
                .monospacedDigit()
            if let model, !model.isEmpty {
                Text("· \(model)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundColor(percent >= 80 ? .orange : .secondary)
        .task {
            while !Task.isCancelled {
                var cbc = cbcSessionID
                if cbc == nil {
                    cbc = await viewModel.findAgentSession(agent: agent, projectDir: projectDir)
                }
                if let cbc, let usage = await viewModel.agentContextUsage(agent: agent, cbcSessionID: cbc, projectDir: projectDir) {
                    percent = usage.percent
                    model = usage.model
                    // Alert the user when context crosses 80%/90% so they can
                    // /compact before the conversation is too long.
                    viewModel.notifyIfContextHigh(sessionID: sessionID, percent: percent)
                }
                // Refresh the selected session frequently; background sessions
                // refresh slowly to reduce backend load.
                let active = viewModel.selectedSession?.id == sessionID
                if percent != 0 || model != nil {
                    try? await Task.sleep(nanoseconds: (active ? 60 : 180) * 1_000_000_000)
                } else {
                    // Backend may not be ready yet on launch; retry quickly.
                    try? await Task.sleep(nanoseconds: (active ? 5 : 30) * 1_000_000_000)
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
                // Session name on the first line (with the pinned star inline
                // before it) so a long name is never truncated by the star.
                HStack(spacing: 4) {
                    if session.pinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.yellow)
                    }
                    Text(session.name)
                        .font(.system(size: 13))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                }

                // Conversation context usage, under the session name.
                // Only agent-bound sessions get a context row. The cbc order:
                // restore/known → live-detected (so a freshly launched agent's
                // conversation shows up without waiting for a restore write) →
                // detected type with no cbc yet (find-session fallback). A
                // plain bash session renders NO row at all.
                //
                // Detection state comes from the viewModel (published globally)
                // rather than the manager param so the row updates even when
                // it is not observing the manager.
                let currentAgent = viewModel.currentAgentType(for: session.id)
                let detectedAgent = viewModel.detectedAgents[session.id]
                let detectedCBC = viewModel.detectedCBCs[session.id]
                if let cbc = session.cbcSessionID, !cbc.isEmpty {
                    ContextUsageView(sessionID: session.id, agent: currentAgent, cbcSessionID: cbc, projectDir: session.projectDir)
                } else if let detectedCBC, !detectedCBC.isEmpty {
                    ContextUsageView(sessionID: session.id, agent: currentAgent, cbcSessionID: detectedCBC, projectDir: session.projectDir)
                } else if let detectedAgent {
                    // An agent was detected but the viewModel has no CBC for it
                    // yet. Pass the manager's precisely detected conversation
                    // id instead of nil: nil makes the row fall back to a
                    // project-wide find-session guess, which can point at
                    // another session's conversation — its usage (including
                    // the model name) then never reflects this session.
                    ContextUsageView(sessionID: session.id, agent: detectedAgent, cbcSessionID: manager?.detectedCBCSessionID, projectDir: session.projectDir)
                } else if viewModel.isAgentMode(for: session.id) {
                    // Agent-mode session restored after launch: detection state
                    // (detectedAgents) is in-memory and gone after restart, and
                    // a resume-less agent (claude) has no cbc in restore.json.
                    // The restore entry still records launchMode=.agent, so keep
                    // the context row visible; findAgentSession resolves the cbc.
                    ContextUsageView(sessionID: session.id, agent: currentAgent, cbcSessionID: nil, projectDir: session.projectDir)
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

                    // Agent badge to the right of the elapsed duration. Kept on
                    // this line (not the name line) so a long session name is
                    // never truncated by it.
                    AgentBadge(
                        manager: manager,
                        configuredAgent: viewModel.configuredAgentType(for: session.id),
                        isAgentSession: (session.cbcSessionID != nil && !session.cbcSessionID!.isEmpty)
                            || viewModel.isAgentMode(for: session.id)
                    )
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

/// Session search field. Lives at the bottom of the sidebar (below the list),
/// keeping the top strip free for the bigger terminal area. Cmd+F focuses it.
struct SessionSearchField: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
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
        .onChange(of: viewModel.searchFocusToken) { _ in
            searchFocused = true
        }
    }
}
