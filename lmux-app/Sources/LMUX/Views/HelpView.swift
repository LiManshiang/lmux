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
                Text(L("lmux Help"))
                    .font(.title2).bold()
                Spacer()
                Button { viewModel.showHelp = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .iconButtonChrome()
                .help(L("Close"))
                .accessibilityLabel(L("Close help"))
            }

            Text(L("lmux is a terminal session manager for AI agents. Each session runs a shell and can launch CodeBuddy or Claude; the sidebar shows each session's agent, status, and context usage."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                Text(L("Keyboard Shortcuts")).font(.headline)
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
                Text(L("Sessions")).font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    helpRow("Create a session with ⌘N, then run an agent inside the terminal.")
                    helpRow("When an agent is detected, the sidebar shows its badge, status (running/idle) and context usage percentage.")
                    helpRow("Use ⌘F to filter sessions, ⌘↑/⌘↓ to switch between them.")
                }
            }

            Group {
                Text(L("Agent Conversations")).font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    helpRow("A session's agent keeps its work in one conversation. lmux remembers which one, so restarting the session resumes it.")
                    helpRow("/clear starts a new conversation. lmux follows it: the sidebar reads the new one and the next restart continues it. The finished conversation is left untouched and stays in the conversation library.")
                    helpRow("/resume switches to a different conversation that already exists. lmux cannot see that — nothing new is written — so the session keeps the one it had and a restart returns to it. To continue where you switched to, set the session's ID to that conversation in Edit Session.")
                    helpRow("/model does not start a conversation: the switch is recorded inside the current one, so nothing changes for the session.")
                    helpRow("/compact does not start a conversation either — and neither does the compaction the agent runs by itself when the context fills up. It summarizes the earlier part, and from then on the agent reads only what follows. Sync copies a session from that point, so a session synced to another machine arrives with the summary and everything after it, not the full scrollback. Nothing is deleted on the machine that has the full history; that only changes if it later imports a copy back.")
                }
            }

            Group {
                Text(L("Backup & Migration")).font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    helpRow("Session → Export Sessions… packs sessions, settings and agent conversations into a tar.gz.")
                    helpRow("Session → Import Sessions… restores a backup and restarts the backend. If the backup came from a different username, paths are migrated automatically.")
                }
            }

            Text(L("Version") + " " + AppVersion.current + " · lmux")
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
