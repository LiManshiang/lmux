import SwiftUI
import LMUXCore

/// Browser for raw agent conversations (filesystem-level JSONL). Unlike the
/// Sessions list — which only shows conversations lmux created/imported —
/// this shows every conversation an agent has, filterable by agent and
/// project directory, so work from any machine can be found and resumed.
struct AgentConversationsView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var searchText = ""

    private var filterID: String { "\(viewModel.agentFilterName)|\(viewModel.agentFilterProjectDir)" }

    private var filtered: [AgentConversation] {
        let items = viewModel.agentConversations
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter {
            ($0.aiTitle?.lowercased().contains(q) ?? false)
                || ($0.summary?.lowercased().contains(q) ?? false)
                || ($0.cwd?.lowercased().contains(q) ?? false)
                || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            listArea
        }
        .task(id: filterID) {
            await viewModel.loadAgentConversations()
        }
    }

    // MARK: - Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Agent", selection: $viewModel.agentFilterName) {
                Text("All").tag("")
                Text("CodeBuddy").tag("codebuddy")
                Text("Claude").tag("claude")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                TextField("All directories (or type a path)", text: $viewModel.agentFilterProjectDir)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK {
                        viewModel.agentFilterProjectDir = panel.url?.path ?? ""
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .help("Filter to one project directory")
            }

            HStack {
                TextField("Search title, summary, path…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Text("\(filtered.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - List

    @ViewBuilder
    private var listArea: some View {
        if viewModel.agentConversationsLoading && viewModel.agentConversations.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning conversations…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = viewModel.agentConversationsError, viewModel.agentConversations.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await viewModel.loadAgentConversations() }
                }
                .font(.system(size: 11))
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                Text("No conversations found")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Conversations are the raw agent JSONL under ~/.codebuddy/projects and ~/.claude/projects. Sync them across machines from Settings → Sync → Agent Conversations Sync.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filtered) { conv in
                        AgentConversationRow(conv: conv)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                resume(conv)
                            }
                            .contextMenu {
                                Button("Resume in lmux…") { resume(conv) }
                                Button("Open in Terminal") { openExternally(conv) }
                                Divider()
                                Button("Copy Session ID") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(conv.id, forType: .string)
                                }
                            }
                        if conv.id != filtered.last?.id {
                            Divider().padding(.leading, 8)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Actions

    private func resume(_ conv: AgentConversation) {
        Task { await viewModel.resumeAgentConversation(conv) }
    }

    private func openExternally(_ conv: AgentConversation) {
        guard let agent = AgentType(rawValue: conv.agent) else { return }
        TerminalLauncher.openInTerminal(
            agentType: agent,
            sessionID: conv.id,
            cwd: conv.cwd ?? NSHomeDirectory()
        )
    }
}

/// One conversation row: title, summary, agent badge, directory, age.
private struct AgentConversationRow: View {
    let conv: AgentConversation

    private var title: String {
        if let t = conv.aiTitle, !t.isEmpty { return t }
        if let s = conv.summary, !s.isEmpty {
            let one = s.split(separator: "\n").first.map(String.init) ?? s
            return String(one.prefix(48))
        }
        return "Conversation \(conv.id.prefix(8))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(AgentConversationsView.timeAgo(conv.mtime))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            if let s = conv.summary, !s.isEmpty {
                Text(s)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                AgentBadgePill(agentName: conv.agent, small: true)
                if let cwd = conv.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text("\(conv.size / 1024) KB")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// Shared row markers for agent filters/rows. Small badge reused by both
/// session rows and the agent browser.
struct AgentBadgePill: View {
    let agentName: String
    var small = false

    var body: some View {
        Text(agentName == "claude" ? "Claude" : "CodeBuddy")
            .font(.system(size: small ? 8 : 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background((agentName == "claude" ? Color.purple : Color.blue).opacity(0.15))
            .foregroundColor(agentName == "claude" ? .purple : .blue)
            .cornerRadius(3)
    }
}

extension AgentConversationsView {
    static func timeAgo(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
