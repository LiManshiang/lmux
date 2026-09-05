import SwiftUI
import LMUXCore

/// Full-page browser for raw agent conversations (filesystem-level JSONL).
/// Left: filterable list of every conversation of an agent / under a
/// directory. Right: a preview pane that shows the conversation's title,
/// full summary and the most recent readable messages — so you can confirm
/// which conversation to resume before acting on it.
struct AgentBrowserView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var searchText = ""
    @State private var listWidth: CGFloat = 340
    @State private var selectedID: String?

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
        HStack(spacing: 0) {
            leftPane
                .frame(width: listWidth)
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1)
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: filterID) {
            await viewModel.loadAgentConversations()
        }
    }

    // MARK: - Left list

    private var leftPane: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            listArea
        }
        .background(.bar)
    }

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
                    .font(.system(size: 11))
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
                Text("This directory has no conversations on this machine. Conversations live under ~/.codebuddy/projects and ~/.claude/projects; sync them across machines from Settings → Sync → Agent Conversations Sync.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { conv in
                        AgentConversationRow(
                            conv: conv,
                            isSelected: conv.id == selectedID
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedID = conv.id
                            Task { await viewModel.loadAgentPreview(conv) }
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
                        Divider().padding(.leading, 8)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Right preview

    @ViewBuilder
    private var previewPane: some View {
        if let conv = viewModel.agentPreviewConversation {
            VStack(alignment: .leading, spacing: 0) {
                previewHeader(conv)
                Divider()
                previewBody(conv)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 30))
                    .foregroundColor(.secondary)
                Text("Select a conversation to preview")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("Single-click a conversation to read its recent messages before resuming it.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func previewHeader(_ conv: AgentConversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AgentBadgePill(agentName: conv.agent, small: false)
                Spacer()
                Text(AgentBrowserView.timeAgo(conv.mtime))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(conv.aiTitle ?? "Conversation \(conv.id.prefix(8))")
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
            if let cwd = conv.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let summary = conv.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .padding(.top, 2)
            }
            HStack(spacing: 8) {
                Button {
                    resume(conv)
                } label: {
                    Label("Resume in lmux", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    openExternally(conv)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
        .padding(12)
    }

    @ViewBuilder
    private func previewBody(_ conv: AgentConversation) -> some View {
        if viewModel.agentPreviewLoading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading conversation…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let rows = viewModel.agentPreview?.rows, rows.isEmpty {
            VStack(spacing: 6) {
                Text("No readable messages in the recent tail")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let rows = viewModel.agentPreview?.rows {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.role == "user" ? "You" : "Agent")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(row.role == "user" ? .secondary : .accentColor)
                                .textCase(.uppercase)
                            Text(row.text)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(row.role == "user"
                                    ? Color.secondary.opacity(0.08)
                                    : Color.accentColor.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
                .padding(12)
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

/// One conversation row with a selected highlight for single-click preview.
private struct AgentConversationRow: View {
    let conv: AgentConversation
    let isSelected: Bool

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
                Text(AgentBrowserView.timeAgo(conv.mtime))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            if let s = conv.summary, !s.isEmpty {
                Text(s)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                AgentBadgePill(agentName: conv.agent, small: true)
                if let cwd = conv.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("\(conv.size / 1024) KB")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .cornerRadius(4)
    }
}

/// Shared small agent marker.
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

extension AgentBrowserView {
    static func timeAgo(_ unix: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
