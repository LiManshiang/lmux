import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var sidebarWidth: CGFloat = 240
    @AppStorage(TerminalRendererSetting.key) private var selectedRenderer = TerminalBackendFactory.defaultRenderer
    @AppStorage("sidebarTab") private var sidebarTab = "sessions"

    var body: some View {
        VStack(spacing: 0) {
            topTabBar
            Divider()
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

    /// Narrow top bar. The Sessions / Agent switch is overlaid dead-center so
    /// its position never shifts when the renderer badge or version text next
    /// to the app icon changes.
    private var topTabBar: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .frame(width: 15, height: 15)
                Text("lmux")
                    .font(.system(size: 13, weight: .semibold))
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
                    Text(AppVersion.current)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)

            Picker("Browse", selection: $sidebarTab) {
                Text("Sessions").tag("sessions")
                Text("Agent").tag("agent")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .fixedSize()
        }
        .frame(height: 30)
    }

    /// Classic sessions workspace: sidebar list + resizer + terminal detail.
    private var sessionsArea: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                SessionListView()

                Divider()

                // Only "new session" remains at the bottom; the refresh button
                // was removed — the 15s poll keeps the list fresh and its
                // circular-arrow icon read as a misleading "restore".
                HStack {
                    Spacer()
                    Button(action: {
                        Task { await viewModel.quickCreateSession() }
                    }) {
                        Image(systemName: "plus")
                    }
                    .disabled(!viewModel.backendRunning)
                    .help("New session")
                    Spacer()
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
