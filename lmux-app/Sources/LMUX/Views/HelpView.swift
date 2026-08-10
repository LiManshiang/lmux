import SwiftUI
import LMUXCore

/// Help content shown from the Help menu (Cmd+?).
struct HelpView: View {
    @EnvironmentObject var viewModel: ContentViewModel

    private let shortcutsTable: [(keys: String, action: String)] = [
        ("⌘N", "New Session"),
        ("⌘F", "Search Sessions"),
        ("⌘↑ / ⌘↓", "Switch to Previous / Next Session"),
        ("⌘K", "Stop the Selected Session"),
        ("⌘?", "Show This Help"),
        ("⌘Q", "Quit lmux"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("lmux Help")
                    .font(.title2).bold()
                Spacer()
                Button { viewModel.showHelp = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("lmux is a terminal session manager for AI agents. Each session runs a shell and can launch CodeBuddy or Claude; the sidebar shows each session's agent, status, and context usage.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                Text("Keyboard Shortcuts").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(shortcutsTable, id: \.keys) { item in
                        HStack {
                            Text(item.keys)
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .frame(width: 130, alignment: .leading)
                            Text(item.action)
                                .font(.system(size: 12))
                        }
                    }
                }
            }

            Group {
                Text("Sessions").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    helpRow("Create a session with ⌘N, then run an agent inside the terminal.")
                    helpRow("When an agent is detected, the sidebar shows its badge, status (running/idle) and context usage percentage.")
                    helpRow("Use ⌘F to filter sessions, ⌘↑/⌘↓ to switch between them.")
                }
            }

            Group {
                Text("Backup & Migration").font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    helpRow("Session → Export Sessions… packs sessions, settings and agent conversations into a tar.gz.")
                    helpRow("Session → Import Sessions… restores a backup and restarts the backend. If the backup came from a different username, paths are migrated automatically.")
                }
            }

            Text("Version \(AppVersion.current) · lmux")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 460)
    }

    private func helpRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .padding(.top, 5)
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12))
        }
    }
}
