import SwiftUI
import LMUXCore

/// Full-page browser for raw agent conversations (filesystem-level JSONL).
/// Left: filterable list of every conversation of an agent / under a
/// directory. Right: a preview pane that shows the conversation's title,
/// full summary and the most recent readable messages — so you can confirm
/// which conversation to resume before acting on it.
struct AgentBrowserView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @AppStorage("sidebarTab") private var sidebarTab = "sessions"
    @AppStorage("columnWidth") private var listWidth = 275.0
    @State private var searchText = ""
    @State private var selectedID: String?
    @State private var showFavoritesOnly = false
    /// Titles = filter the loaded list in memory (instant). Content = scan the
    /// text of past conversations on the backend (~1s, bounded by default).
    @State private var searchMode: SearchMode = .titles
    @State private var searchAllHistory = false
    /// Selection inside the content results. One conversation can appear
    /// several times, so hit rows carry a unique tag: "conversationID|line".
    @State private var selectedHitKey: String?
    /// Conversation awaiting the delete confirmation dialog.
    @State private var pendingDelete: AgentConversation?
    /// Which content-search hit row the pointer is over (only ever one).
    @State private var hoveredHitKey: String?
    /// Lets ⌘F put the cursor in the browser's search field too (the sidebar
    /// field used to be the only one listening to the focus token).
    @FocusState private var contentSearchFocused: Bool

    enum SearchMode: String, CaseIterable, Identifiable {
        case titles
        case content
        var id: String { rawValue }
        var label: String { self == .titles ? "Titles" : "Content" }
        var placeholder: String {
            self == .titles ? "Search title, summary, path…" : "Search inside conversations…"
        }
    }

    /// Changing any of these restarts the content search; SwiftUI cancels the
    /// previous task, which drops the in-flight request and stops the scan.
    private var contentSearchKey: String {
        "\(searchMode.rawValue)|\(searchText)|\(searchAllHistory)|\(viewModel.agentFilterName)|\(viewModel.agentFilterProjectDir)"
    }

    private var filterID: String { "\(viewModel.agentFilterName)|\(viewModel.agentFilterProjectDir)" }

    /// Dropdown choices: the two known agents plus any extra agent found in the
    /// current result set (so a future third agent appears automatically).
    private var agentMenuOptions: [String] {
        var set = Set(viewModel.agentConversations.map(\.agent))
        set.insert(viewModel.agentFilterName)
        set.insert("codebuddy")
        set.insert("claude")
        return set.filter { !$0.isEmpty }.sorted()
    }

    static func displayName(for agent: String) -> String {
        switch agent {
        case "codebuddy": return "CodeBuddy"
        case "claude": return "Claude"
        default: return agent
        }
    }

    private var filtered: [AgentConversation] {
        var items = viewModel.agentConversations
        if showFavoritesOnly {
            items = items.filter { viewModel.agentStars.contains($0.id) }
        }
        guard !searchText.isEmpty else { return items }
        let q = searchText.lowercased()
        return items.filter {
            ($0.aiTitle?.lowercased().contains(q) ?? false)
                || ($0.summary?.lowercased().contains(q) ?? false)
                || ($0.cwd?.lowercased().contains(q) ?? false)
                || $0.id.lowercased().contains(q)
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the content-results list should drive the pane right now.
    private var showingContentResults: Bool {
        searchMode == .content && !trimmedQuery.isEmpty
    }

    /// Count beside the search field: matches in content mode, rows in title mode.
    private var resultCount: Int {
        if showingContentResults {
            return viewModel.agentSearchResults?.results.reduce(0) { $0 + $1.hits.count } ?? 0
        }
        return filtered.count
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: CGFloat(listWidth))
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1)
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Debounced content search. The id covers every input that changes the
        // answer, so SwiftUI cancels the previous run (and its HTTP request)
        // whenever one of them changes.
        .task(id: contentSearchKey) {
            guard searchMode == .content else { return }
            await viewModel.searchAgentConversations(
                query: searchText,
                agent: viewModel.agentFilterName,
                projectDir: viewModel.agentFilterProjectDir,
                all: searchAllHistory
            )
        }
        // Deleting a conversation is irreversible, so it always goes through
        // this confirmation.
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { conv in
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteAgentConversation(conv) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { conv in
            Text(deleteWarning(for: conv))
        }
        .onChange(of: viewModel.searchFocusToken) { _ in
            contentSearchFocused = true
        }
        .task(id: filterID) {
            // A different agent or directory means the preview and any search
            // results on screen belong to a set the user is no longer looking
            // at; clear them so nothing stale is shown or acted on.
            viewModel.resetAgentBrowsingState()
            selectedID = nil
            selectedHitKey = nil
            await viewModel.loadAgentConversations()
        }
    }

    // MARK: - Left list

    private var leftPane: some View {
        VStack(spacing: 0) {
            // Sessions/Agent switch pinned to the top-left, same spot as on the
            // Sessions page, so toggling pages doesn't make the control jump.
            HStack(spacing: 0) {
                Picker("Browse", selection: $sidebarTab) {
                    Text("Sessions").tag("sessions")
                    Text("Agent").tag("agent")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Browse sessions or agent conversations")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            filters
            Divider()
            listArea
        }
        .background(.bar)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                // Dropdown rather than segmented tabs so additional agents can
                // be added later without overflowing the row. Options are the
                // known agents plus any agent present in the loaded data.
                Picker("Agent", selection: $viewModel.agentFilterName) {
                    Text("All agents").tag("")
                    ForEach(agentMenuOptions, id: \.self) { name in
                        Text(AgentBrowserView.displayName(for: name)).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

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

            HStack(spacing: 6) {
                Picker("", selection: $searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                TextField(searchMode.placeholder, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .focused($contentSearchFocused)
                    .onExitCommand {
                        if !trimmedQuery.isEmpty {
                            searchText = ""
                        } else {
                            contentSearchFocused = false
                        }
                    }
                Button {
                    showFavoritesOnly.toggle()
                } label: {
                    Image(systemName: showFavoritesOnly ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundColor(showFavoritesOnly ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Show favorites only")
                Text("\(resultCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if searchMode == .content {
                HStack(spacing: 6) {
                    Toggle("Search all history", isOn: $searchAllHistory)
                        .font(.system(size: 10))
                        .toggleStyle(.checkbox)
                        .help("Off: recent conversations only (about a second). On: every conversation (a few seconds).")
                    Spacer()
                    if viewModel.agentSearchInFlight {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            if viewModel.agentHiddenBound > 0 {
                Text("\(viewModel.agentHiddenBound) bound conversation(s) already in Sessions are hidden")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var listArea: some View {
        if viewModel.agentBackendDown {
            VStack(spacing: 6) {
                Image(systemName: "bolt.slash")
                    .font(.system(size: 20))
                    .foregroundColor(.orange)
                Text("The backend is not running")
                    .font(.system(size: 12))
                Text("Conversations are listed by the local backend. It starts with the app; use Retry if it has stopped.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button("Retry") {
                    Task { await viewModel.loadAgentConversations() }
                }
                .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.agentConversationsLoading && viewModel.agentConversations.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning conversations…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = viewModel.agentConversationsError, viewModel.agentConversations.isEmpty {
            PaneMessage(
                icon: "exclamationmark.triangle",
                title: err,
                retry: { Task { await viewModel.loadAgentConversations() } }
            )
        } else if showingContentResults {
            contentResultsArea
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
            let favorites = filtered.filter { viewModel.agentStars.contains($0.id) }
            let others = filtered.filter { !viewModel.agentStars.contains($0.id) }
            List(selection: $selectedID) {
                if showFavoritesOnly {
                    ForEach(favorites) { conversationRow($0) }
                } else {
                    if !favorites.isEmpty {
                        Section {
                            ForEach(favorites) { conversationRow($0) }
                        } header: {
                            Text("Favorites")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    ForEach(others) { conversationRow($0) }
                }
            }
            .listStyle(.inset)
            .onChange(of: selectedID) { newID in
                // The List owns single-click selection (no double-click gesture
                // on rows — it fights the List's click handling and delays
                // every click). Clicking the already-selected row reloads it.
                guard let newID,
                      let conv = filtered.first(where: { $0.id == newID }) else { return }
                if newID != viewModel.agentPreviewConversation?.id {
                    Task { await viewModel.loadAgentPreview(conv) }
                }
            }
        }
    }

    // MARK: - Content search results

    @ViewBuilder
    private var contentResultsArea: some View {
        if let err = viewModel.agentSearchError {
            PaneMessage(icon: "exclamationmark.triangle", title: err) {
                Task {
                    await viewModel.searchAgentConversations(
                        query: searchText,
                        agent: viewModel.agentFilterName,
                        projectDir: viewModel.agentFilterProjectDir,
                        all: searchAllHistory,
                        // 0 seconds: skip the debounce for an explicit retry.
                        debounce: 0
                    )
                }
            }
        } else if let result = viewModel.agentSearchResults, !result.results.isEmpty {
            VStack(spacing: 0) {
                contentSearchMeta(result)
                List(selection: $selectedHitKey) {
                    ForEach(result.results) { group in
                        Section {
                            ForEach(group.hits) { hit in
                                contentHitRow(group: group, hit: hit)
                            }
                        } header: {
                            contentGroupHeader(group)
                        }
                    }
                }
                .listStyle(.inset)
                .onChange(of: selectedHitKey) { key in
                    guard let key,
                          let convID = key.split(separator: "|").first.map(String.init),
                          let conv = viewModel.agentConversations.first(where: { $0.id == convID })
                            ?? result.results.first(where: { $0.conversation.id == convID })?.conversation
                    else { return }
                    if convID != viewModel.agentPreviewConversation?.id {
                        Task { await viewModel.loadAgentPreview(conv) }
                    }
                }
            }
        } else if viewModel.agentSearchInFlight {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(searchAllHistory ? "Searching every conversation…" : "Searching recent conversations…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)
                Text("No matches in conversation text")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if !searchAllHistory {
                    Text("Try “Search all history” to include older conversations.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One line above the results: how much was scanned and how long it took.
    private func contentSearchMeta(_ result: ConversationSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(result.results.count) conversation(s) · \(resultCount) match(es)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.2fs", Double(result.elapsedMS) / 1000))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if result.truncated {
                Text("Showing the first \(resultCount) matches — narrow the query to see the rest.")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }
            if result.timedOut {
                Text("Search timed out after \(result.scanned) conversation(s) — try a narrower query.")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func contentGroupHeader(_ group: ConversationSearchGroup) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(group.conversation.aiTitle?.isEmpty == false
                 ? group.conversation.aiTitle!
                 : String(group.conversation.id.prefix(12)))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            if let cwd = group.conversation.cwd, !cwd.isEmpty {
                Text((cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    /// Stable identity for one hit row (a conversation appears several times).
    private func hitKey(_ group: ConversationSearchGroup, _ hit: ConversationSearchHit) -> String {
        "\(group.conversation.id)|\(hit.line)"
    }

    private func contentHitRow(group: ConversationSearchGroup, hit: ConversationSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: hit.role == "user" ? "person.fill" : "sparkles")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                Text(hit.role == "user" ? "You" : AgentBrowserView.displayName(for: group.conversation.agent))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            Text(highlighted(hit.snippet, query: trimmedQuery))
                .font(.system(size: 10))
                .lineLimit(3)
        }
        .listRowBackground(hoveredHitKey == hitKey(group, hit) ? Color.primary.opacity(0.05) : nil)
        .onHover { over in
            let key = hitKey(group, hit)
            hoveredHitKey = over ? key : (hoveredHitKey == key ? nil : hoveredHitKey)
        }
        .tag(hitKey(group, hit))
        .contextMenu {
            Button("Resume in lmux…") { resume(group.conversation) }
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(group.conversation.id, forType: .string)
            }
            Divider()
            Button("Delete Conversation…", role: .destructive) {
                pendingDelete = group.conversation
            }
        }
    }

    /// Highlights every occurrence of the query inside a snippet.
    private func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let found = attributed[searchStart...].range(of: query, options: .caseInsensitive) {
            attributed[found].backgroundColor = .yellow.opacity(0.35)
            attributed[found].font = .system(size: 10, weight: .semibold)
            if found.upperBound <= searchStart { break } // safety: never loop
            searchStart = found.upperBound
        }
        return attributed
    }

    /// Copy for the delete confirmation. Adds a caution when the file was
    /// written seconds ago, which usually means an agent is still using it.
    private func deleteWarning(for conv: AgentConversation) -> String {
        let name = (conv.aiTitle?.isEmpty == false)
            ? conv.aiTitle!
            : "Conversation \(conv.id.prefix(8))"
        var text = """
        “\(name)” will be deleted from this Mac (~/.codebuddy/projects). \
        This cannot be undone, and the deletion is not synced to your other Macs.
        """
        // Judge by whether a session is bound to it rather than by file age:
        // an agent that finished a turn (and is now waiting for input) stops
        // writing, so a fresh mtime is not the only sign of being in use.
        if let bound = viewModel.sessions.first(where: { $0.cbcSessionID == conv.id }) {
            text += "\n\n⚠️ The session “\(bound.name)” is bound to it; deleting will detach that session."
        }
        return text
    }

    private func conversationRow(_ conv: AgentConversation) -> some View {
        AgentConversationRow(
            conv: conv,
            isStarred: viewModel.agentStars.contains(conv.id),
            onToggleStar: { viewModel.toggleAgentStar(conv.id) }
        )
        .tag(conv.id)
        .contextMenu {
            Button("Resume in lmux…") { resume(conv) }
            Button("Open in Terminal.app") { openExternally(conv) }
            Divider()
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(conv.id, forType: .string)
            }
            Divider()
            Button("Delete Conversation…", role: .destructive) {
                pendingDelete = conv
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
                Button {
                    viewModel.toggleAgentStar(conv.id)
                } label: {
                    Image(systemName: viewModel.agentStars.contains(conv.id) ? "star.fill" : "star")
                        .foregroundColor(viewModel.agentStars.contains(conv.id) ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .iconButtonChrome()
                .help("Favorite")
                .accessibilityLabel("Favorite conversation")
                AgentBadgePill(agentName: conv.agent, small: false)
                Spacer()
                Button {
                    pendingDelete = conv
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .iconButtonChrome()
                .help("Delete this conversation file (asks first)")
                .accessibilityLabel("Delete conversation")
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
                    // Capped: an unbounded summary took over the whole pane
                    // and pushed the messages off screen.
                    .lineLimit(4)
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
        previewBodyContent(conv)
            // The id matters: without it the view keeps its identity across
            // conversations and the transition below never runs.
            .id(conv.id)
            // Swapping conversations replaced the pane instantly; a short fade
            // reads as new content without the drag of a slide.
            .animation(.easeOut(duration: 0.15), value: viewModel.agentPreviewConversation?.id)
            .transition(.opacity)
    }

    @ViewBuilder
    private func previewBodyContent(_ conv: AgentConversation) -> some View {
        if viewModel.agentPreviewLoading {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading conversation…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.agentPreviewError {
            PaneMessage(
                icon: "exclamationmark.triangle",
                title: "Could not read this conversation",
                detail: error,
                retry: { Task { await viewModel.loadAgentPreview(conv) } }
            )
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
                        HStack(alignment: .top, spacing: 6) {
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

                            if row.role == "user" {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(row.text, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .iconButtonChrome()
                                .help("Copy this prompt (reuse it after Resume)")
                                .accessibilityLabel("Copy prompt")
                                .padding(.top, 6)
                            }
                        }
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
        let launched = TerminalLauncher.openInTerminal(
            agentType: agent,
            sessionID: conv.id,
            cwd: conv.cwd ?? NSHomeDirectory()
        )
        if !launched {
            viewModel.showToast("Could not open Terminal for this conversation")
        }
    }
}

/// One conversation row; selection highlighting is managed by the enclosing
/// List.
private struct AgentConversationRow: View {
    let conv: AgentConversation
    let isStarred: Bool
    let onToggleStar: () -> Void

    /// macOS `List` gives no hover highlight here, so the row supplies its own.
    /// Passing nil when idle keeps the list's own selection colour intact.
    @State private var isHovering = false

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
                Button(action: onToggleStar) {
                    Image(systemName: isStarred ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundColor(isStarred ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(isStarred ? "Remove from favorites" : "Add to favorites")
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
        .padding(.vertical, 5)
        .listRowBackground(isHovering ? Color.primary.opacity(0.05) : nil)
        .onHover { isHovering = $0 }
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
    /// Compact relative time for list rows (see RelativeTime).
    static func timeAgo(_ unix: Int64) -> String { RelativeTime.short(unix) }
}
