import SwiftUI
import AppKit
import LMUXCore

/// Cross-device sync settings: enable flag, cloud directory, path mappings.
struct SyncSettingsView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var syncEnabled = SessionSync.isEnabled
    @State private var syncDir = SessionSync.syncDir ?? ""
    @State private var mappings = SessionSync.pathMappings

    var body: some View {
        Form {
            Section("Cross-Device Sync") {
                Toggle("Enable session sync", isOn: $syncEnabled)
                    .toggleStyle(.switch)

                Text("Only pinned (starred) sessions sync. Sync is manual: use “Sync Now”, or confirm on quit when pinned sessions exist. Two-way: local changes export, remote changes import. Conflicts create a copy. Deletions do not propagate.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Button {
                    Task {
                        let result = await viewModel.syncNow()
                        viewModel.reportSyncResult(result)
                    }
                } label: {
                    HStack(spacing: 4) {
                        if viewModel.syncInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(viewModel.syncInProgress ? "Syncing…" : "Sync Now")
                    }
                }
                .disabled(!syncEnabled || viewModel.syncInProgress)
            }

            Section("Sync Directory") {
                HStack(spacing: 6) {
                    TextField("~/Library/Mobile Documents/…/lmux-sync", text: $syncDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.canCreateDirectories = true
                        panel.message = "Select a directory that syncs to your other machines (iCloud Drive, Syncthing, …)"
                        if panel.runModal() == .OK {
                            syncDir = panel.url?.path ?? syncDir
                        }
                    }
                }
            }

            Section("Path Mappings (old machine path → this machine)") {
                ForEach($mappings) { $mapping in
                    HStack(spacing: 6) {
                        TextField("/Users/limanshiang/proj", text: $mapping.from)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        TextField("/Users/manshiangli/proj", text: $mapping.to)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            mappings.removeAll { $0.id == mapping.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    mappings.append(PathMapping(from: "", to: ""))
                } label: {
                    Image(systemName: "plus.circle")
                    Text("Add Mapping")
                }
                .buttonStyle(.plain)
            }
        }
        .groupedForm()
        .onChange(of: syncEnabled) { _ in persistSyncSettings() }
        .onChange(of: syncDir) { _ in persistSyncSettings() }
        .onChange(of: mappings) { _ in persistSyncSettings() }
    }

    private func persistSyncSettings() {
        SessionSync.isEnabled = syncEnabled
        SessionSync.syncDir = syncDir.isEmpty ? nil : syncDir
        SessionSync.pathMappings = mappings.filter { !$0.from.isEmpty && !$0.to.isEmpty }
    }
}
