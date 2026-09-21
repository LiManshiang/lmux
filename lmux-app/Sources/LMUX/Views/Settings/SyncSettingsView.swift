import SwiftUI
import AppKit
import LMUXCore

/// Cross-device sync settings: enable flag, cloud directory, path mappings.
struct SyncSettingsView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var syncEnabled = SessionSync.isEnabled
    @State private var syncDir = SessionSync.syncDir ?? ""
    @State private var mappings = SessionSync.pathMappings
    @State private var agentMirrorEnabled = SessionSync.agentMirrorEnabled
    @State private var compactionOnly = SessionSync.compactionOnly

    var body: some View {
        Form {
            Section(L("Cross-Device Sync")) {
                Toggle(L("Enable session sync"), isOn: $syncEnabled)
                    .toggleStyle(.switch)

                Text(L("Only pinned (starred) sessions sync. Sync is manual: use “Sync Now”, or confirm on quit when pinned sessions exist. Two-way: local changes export, remote changes import. Conflicts create a copy. Deletions do not propagate."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    // fixedSize so the row is allowed the height the text needs
                    // (without it macOS 13+ cuts the hint to one line and ends it
                    // with an ellipsis), plus a trailing inset so the last glyph
                    // is not flush against the window edge, which is where the
                    // narrower macOS 12 layout put it.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 14)

                Toggle(L("Sync only from the last compaction point"), isOn: $compactionOnly)
                    .toggleStyle(.switch)
                    .disabled(!syncEnabled)

                Text(L("Full sync also carries the conversation before this Mac's last compaction point: content the agent no longer reads, and most of the size. Syncing from the compaction point rewrites this Mac's conversation to drop it — that content is lost for good — and frees the space."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    // fixedSize so the row is allowed the height the text needs
                    // (without it macOS 13+ cuts the hint to one line and ends it
                    // with an ellipsis), plus a trailing inset so the last glyph
                    // is not flush against the window edge, which is where the
                    // narrower macOS 12 layout put it.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 14)

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

            Section(L("Sync Directory")) {
                HStack(spacing: 6) {
                    // The example path goes in `prompt:`, not in the title. As a
                    // title it becomes the row's *label*, and in the Form style
                    // macOS 12 uses (`.columns`) the label column is sized by its
                    // widest label — so this one string stretched that column to
                    // ~520pt of the 600pt window and pushed every row's content,
                    // including the hints below and the Browse button, off the
                    // right edge where the window clipped it.
                    TextField("", text: $syncDir,
                              prompt: Text("~/Library/Mobile Documents/…/lmux-sync"))
                        .textFieldStyle(.roundedBorder)
                    Button(L("Browse...")) {
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

            Section(L("Agent Conversations Sync")) {
                Toggle(L("Mirror all agent conversations"), isOn: $agentMirrorEnabled)
                    .toggleStyle(.switch)

                Text(L("Raw agent JSONL under ~/.codebuddy/projects and ~/.claude/projects is mirrored to <sync dir>/agents and pulled back on other machines, so the Agent browser can find and resume every conversation. Only .jsonl files up to 50 MB sync; two-way changes keep the local copy."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    // fixedSize so the row is allowed the height the text needs
                    // (without it macOS 13+ cuts the hint to one line and ends it
                    // with an ellipsis), plus a trailing inset so the last glyph
                    // is not flush against the window edge, which is where the
                    // narrower macOS 12 layout put it.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 14)
            }

            Section(L("Path Mappings")) {
                ForEach($mappings) { $mapping in
                    HStack(spacing: 6) {
                        // Same reason as the sync directory above: an example path
                        // as a TextField title becomes a label, and the label
                        // column is sized by the widest one in the whole Form.
                        TextField("", text: $mapping.from,
                                  prompt: Text("/Users/limanshiang/proj"))
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        TextField("", text: $mapping.to,
                                  prompt: Text("/Users/manshiangli/proj"))
                            .textFieldStyle(.roundedBorder)
                        Button {
                            mappings.removeAll { $0.id == mapping.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .iconButtonChrome()
                        .help(L("Remove mapping"))
                        .accessibilityLabel(L("Remove path mapping"))
                    }
                }

                Button {
                    mappings.append(PathMapping(from: "", to: ""))
                } label: {
                    Image(systemName: "plus.circle")
                    Text(L("Add Mapping"))
                }
                .buttonStyle(.plain)

                // What the old, longer section title said. As a title it was cut
                // off at the window edge on macOS 12, where a Form lays a section
                // header out on one line.
                Text(L("Maps a path recorded on another machine to where it lives here. Applied when a session is imported, so a session that referred to the old layout finds its directory on this one."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 14)
            }
        }
        .formScrollable()
        .groupedForm()
        .onChange(of: syncEnabled) { _ in persistSyncSettings() }
        .onChange(of: syncDir) { _ in persistSyncSettings() }
        .onChange(of: mappings) { _ in persistSyncSettings() }
        .onChange(of: agentMirrorEnabled) { _ in persistSyncSettings() }
        .onChange(of: compactionOnly) { _ in persistSyncSettings() }
    }

    private func persistSyncSettings() {
        SessionSync.isEnabled = syncEnabled
        SessionSync.syncDir = syncDir.isEmpty ? nil : syncDir
        SessionSync.pathMappings = mappings.filter { !$0.from.isEmpty && !$0.to.isEmpty }
        SessionSync.agentMirrorEnabled = agentMirrorEnabled
        SessionSync.compactionOnly = compactionOnly
    }
}
