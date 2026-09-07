import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    // Shared column width: the Sessions sidebar and the Agent list pane use the
    // same AppStorage key so switching pages keeps the same geometry.
    @AppStorage("columnWidth") private var sidebarWidth = 275.0
    @AppStorage(TerminalRendererSetting.key) private var selectedRenderer = TerminalBackendFactory.defaultRenderer
    @AppStorage("sidebarTab") private var sidebarTab = "sessions"

    var body: some View {
        Group {
            if sidebarTab == "agent" {
                AgentBrowserView()
                    .environmentObject(viewModel)
            } else {
                sessionsArea
            }
        }
        .overlay(alignment: .top) {
            if let msg = viewModel.toastMessage {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color(NSColor.controlBackgroundColor)))
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
                    .shadow(color: .black.opacity(0.15), radius: 4)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            // Modal "syncing" wait indicator: sync exports every pinned
            // session plus the agent JSONL mirror, which can take a while.
            // (Quit-time sync shows its own panel and keeps this hidden.)
            if viewModel.syncWaitVisible {
                SyncWaitingView(phase: viewModel.syncPhase)
            }
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.toastMessage)
        .sheet(isPresented: $viewModel.showHelp) {
            HelpView()
        }
        .sheet(isPresented: $viewModel.showMirrorConflicts) {
            MirrorConflictPanelView()
                .environmentObject(viewModel)
        }
        .sheet(item: $viewModel.editingSession) { session in
            EditSessionSheet(session: session)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.showUsageStats) {
            UsageStatsView()
                .environmentObject(viewModel)
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
            if !viewModel.backendRunning && !viewModel.backendStarting {
                Button("Retry Backend") {
                    viewModel.retryBackend()
                }
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    /// The renderer badge (Ghostty when active, SwiftTerm otherwise).
    private var rendererBadge: some View {
        HStack(spacing: 4) {
#if canImport(GhosttyTerminal)
            if selectedRenderer == TerminalRendererSetting.ghostty {
                Text("Ghostty")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(4)
            } else {
                Text("SwiftTerm")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
#else
            Text("SwiftTerm")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
#endif
        }
    }

    /// App identity row shown at the very bottom of the sessions sidebar:
    /// icon + name + renderer + version, left of the new-session button.
    private var appIdentity: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 15, height: 15)
            Text("lmux")
                .font(.system(size: 12, weight: .semibold))
            rendererBadge
            Text(AppVersion.current)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    /// Classic sessions workspace: sidebar list + resizer + terminal detail.
    private var sessionsArea: some View {
        HStack(spacing: 0) {
            // Sidebar (top → bottom): tab switch, search, session list,
            // New Session button, app identity + overflow menu. No top strip,
            // so the terminal area is taller.
            VStack(spacing: 0) {
                // Sessions/Agent switch pinned to the top-left, matching the
                // Agent page so switching pages doesn't jump the control.
                HStack(spacing: 0) {
                    tabSwitch
                        .fixedSize()
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()

                // Search sits at the top of the session column.
                SessionSearchField()

                SessionListView()

                Divider()

                // New session as a full-width button above the footer row.
                Button(action: {
                    Task { await viewModel.quickCreateSession() }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New Session")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.backendRunning)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()

                HStack(spacing: 8) {
                    appIdentity
                    Spacer()
                    bottomMenu
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(width: CGFloat(sidebarWidth))
            .background(.bar)

            // Resizer
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1)

            // Detail area
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The (⋯) overflow menu in place of the old bottom "+": sync, settings,
    /// about.
    private var bottomMenu: some View {
        Menu {
            Button {
                Task {
                    let result = await viewModel.syncNow()
                    viewModel.reportSyncResult(result)
                }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button {
                SettingsWindowController.shared.open(viewModel: viewModel)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Divider()
            Button {
                NSApp.orderFrontStandardAboutPanel(nil)
            } label: {
                Label("About lmux", systemImage: "info.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .menuIndicator(.hidden)
        .help("Sync Now, Settings…, About…")
    }

    /// Sessions / Agent switch, now in the sidebar strip where the search box
    /// used to be (search moved to the bottom, above the identity row).
    private var tabSwitch: some View {
        Picker("Browse", selection: $sidebarTab) {
            Text("Sessions").tag("sessions")
            Text("Agent").tag("agent")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Browse sessions or agent conversations")
    }

    @ViewBuilder
    private var detailView: some View {
        if viewModel.selectedSession != nil {
            SessionDetailView()
        } else if !viewModel.backendRunning && !viewModel.backendStarting {
            BackendNotRunningView()
        } else if !viewModel.backendRunning {
            BackendLoadingView()
        } else {
            EmptyStateView()
        }
    }
}

struct BackendNotRunningView: View {
    @EnvironmentObject var viewModel: ContentViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Backend Not Running")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Start the lmux backend to manage sessions.")
                .font(.body)
                .foregroundColor(.secondary)
            Button("Start Backend") {
                viewModel.retryBackend()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Session Selected")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Select a session from the sidebar or create a new one.")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BackendLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Connecting to Backend...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Modal wait indicator shown while Sync Now is running (exporting every
/// pinned session plus the agent JSONL mirror can take a while).
struct SyncWaitingView: View {
    let phase: ContentViewModel.SyncPhase

    private var title: String {
        switch phase {
        case .idle:
            return "Syncing sessions…"
        case .importing:
            return "Importing session…"
        case .exporting(let current, let total):
            return "Exporting session \(current) of \(total)"
        case .mirroring(let detail):
            return "Agent conversations · \(detail)"
        }
    }

    private var subtitle: String {
        switch phase {
        case .importing:
            return "Large conversation bundles can take a while to transfer"
        default:
            return "Syncing pinned sessions and agent conversations"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
    }
}