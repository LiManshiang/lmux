import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var sidebarWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
                HStack {
                    Text("Sessions")
                        .font(.headline)
                    Spacer()
                    Text(AppVersion.current)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                SessionListView()

                Divider()

                HStack {
                    Button(action: { Task { await viewModel.refreshSessions() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!viewModel.backendRunning || viewModel.isLoading)

                    Spacer()

                    Button(action: {
                        Task { await viewModel.quickCreateSession() }
                    }) {
                        Image(systemName: "plus")
                    }
                    .disabled(!viewModel.backendRunning)
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
