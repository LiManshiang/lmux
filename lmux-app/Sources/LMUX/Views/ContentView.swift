import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var sidebarWidth: CGFloat = 240
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
        .animation(.easeOut(duration: 0.2), value: viewModel.toastMessage)
        .sheet(isPresented: $viewModel.showHelp) {
            HelpView()
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
            // Sidebar (top → bottom): tab switch, session list, search,
            // app identity + new session. No top strip, so the terminal area
            // is taller.
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    tabSwitch
                        .fixedSize()
                    Spacer()
                }
                .padding(.vertical, 6)

                Divider()

                SessionListView()

                Divider()

                SessionSearchField()

                Divider()

                HStack(spacing: 8) {
                    appIdentity
                    Spacer()
                    Button(action: {
                        Task { await viewModel.quickCreateSession() }
                    }) {
                        Image(systemName: "plus")
                    }
                    .disabled(!viewModel.backendRunning)
                    .help("New session")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(width: sidebarWidth)
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
