import SwiftUI
import LMUXCore

/// Surfaces two-way agent-mirror conflicts after a Sync Now pass. Both this
/// machine and the mirror grew a conversation file since the last sync, so
/// neither side automatically wins — the user picks per file.
struct MirrorConflictPanelView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Agent Conversation Conflicts")
                .font(.system(size: 14, weight: .semibold))
            Text("These conversations changed on both this machine and the sync mirror. Local copies were kept — choose \"Use mirror\" to take the other version instead.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .padding(12)

        Divider()

        if viewModel.mirrorConflicts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 26))
                    .foregroundColor(.green)
                Text("No unresolved conflicts")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.mirrorConflicts) { conflict in
                        row(conflict)
                        Divider().padding(.leading, 12)
                    }
                }
            }
        }

        Divider()

        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private func row(_ conflict: SessionSync.AgentMirrorConflict) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AgentBadgePill(agentName: conflict.agentName, small: true)
                Text(conflict.fileRel)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 12) {
                Text("Local · \(Self.kb(conflict.localSize)) · \(Self.timeAgo(conflict.localMTime))")
                Text("Mirror · \(Self.kb(conflict.remoteSize)) · \(Self.timeAgo(conflict.remoteMTime))")
            }
            .font(.system(size: 9))
            .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button {
                    viewModel.dismissMirrorConflict(id: conflict.id)
                } label: {
                    Label("Keep Local", systemImage: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    viewModel.resolveMirrorConflictUseRemote(conflict)
                } label: {
                    Label("Use Mirror", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func kb(_ size: Int64) -> String {
        size >= 1024 ? "\(size / 1024) KB" : "\(size) B"
    }

    /// Readable relative time for sentences (see RelativeTime).
    private static func timeAgo(_ unix: Int64) -> String { RelativeTime.short(unix, sentence: true) }
}
