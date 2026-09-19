import SwiftUI
import LMUXCore

/// Edit the editable fields of a stopped session: display name, project
/// directory, and the bound conversation ID.
///
/// The directory field is checked against where the bound conversation actually
/// lives, because the two have to agree: the agent resolves `--resume <id>`
/// inside the project folder derived from its working directory, so a session
/// pointing elsewhere cannot resume at all. Getting that wrong is invisible
/// until the next connect, at which point the terminal prints "No conversation
/// found with session ID" — so the mistake is surfaced here instead.
struct EditSessionSheet: View {
    let session: SessionSummary
    @EnvironmentObject var viewModel: ContentViewModel

    @State private var sessionName = ""
    @State private var projectDir = ""
    @State private var cbcSessionID = ""
    @State private var dirExists = false
    @State private var showDirError = false
    /// Result of the last conversation lookup, and the inputs it belongs to —
    /// the check is asynchronous, so a result that arrives after the fields
    /// changed must not be shown as if it described what is on screen.
    @State private var location: ConversationLocation?
    @State private var locationInputs: LocationQuery?

    /// The pair the location check is keyed on. Changing either re-runs it.
    private struct LocationQuery: Hashable {
        let cbcSessionID: String
        let projectDir: String
    }

    /// Set when the typed directory does not hold the bound conversation, so
    /// saving will move it there — the two are the same thing to the agent.
    private var misplacedDir: Bool {
        guard let location, location.found, locationInputs == currentQuery else { return false }
        return !location.matches
    }

    /// Where the conversation's own records say the agent worked, when that is
    /// somewhere else than the typed directory. Offered as a suggestion: it is
    /// where the session's work actually happened, which is usually the
    /// directory the user means.
    @State private var suggestedWorkDir: String?

    /// Set when no file carries this conversation ID at all: the binding is
    /// dead (deleted, or the agent moved to a new conversation after /clear).
    private var conversationMissing: Bool {
        guard let location, locationInputs == currentQuery, !location.found else { return false }
        return true
    }

    private var currentQuery: LocationQuery {
        LocationQuery(cbcSessionID: cbcSessionID.trimmingCharacters(in: .whitespaces), projectDir: normalizedDir)
    }

    private var normalizedDir: String {
        var path = NSString(string: projectDir.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private var hasChanges: Bool {
        sessionName != session.name
            || projectDir != session.projectDir
            || cbcSessionID != (session.cbcSessionID ?? "")
    }

    private var canSave: Bool {
        let trimmed = projectDir.trimmingCharacters(in: .whitespaces)
        // Also reachable with nothing edited: when the session's directory and
        // its conversation are out of step, saving is what puts them back —
        // leaving the button disabled would make the note above it a dead end.
        return !trimmed.isEmpty && dirExists && (hasChanges || misplacedDir || conversationMissing)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(L("Edit Session"))
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Session Name"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Session name", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Project Directory"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("~/Projects/my-project", text: $projectDir)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: projectDir) { newValue in
                                validateDir(newValue)
                            }

                        Button(L("Browse…")) {
                            browseDirectory()
                        }
                    }
                    if showDirError {
                        Text(L("Directory does not exist or is not accessible"))
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    if conversationMissing {
                        Text(L("No conversation file has this session ID"))
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else if misplacedDir {
                        VStack(alignment: .leading, spacing: 4) {
                            // Informational, not a warning: the conversation
                            // travels with the directory, so this is the edit
                            // working as intended.
                            Text(L("Saving will move this conversation here"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let suggestion = suggestedWorkDir {
                                Button(L("It works in %@ — use that", suggestion as NSString)) {
                                    projectDir = suggestion
                                    validateDir(suggestion)
                                }
                                .font(.caption)
                                .buttonStyle(.link)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Session ID (cbc_session_id)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Conversation ID", text: $cbcSessionID)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 12) {
                Spacer()

                Button(L("Cancel")) {
                    viewModel.editingSession = nil
                }

                Button(L("Save")) {
                    let name = sessionName.trimmingCharacters(in: .whitespaces)
                    let dir = projectDir.trimmingCharacters(in: .whitespaces)
                    let cbc = cbcSessionID.trimmingCharacters(in: .whitespaces)

                    Task {
                        await viewModel.editSession(
                            id: session.id,
                            name: name.isEmpty ? nil : name,
                            projectDir: dir.isEmpty ? nil : dir,
                            cbcSessionID: cbc.isEmpty ? nil : cbc
                        )
                    }
                    viewModel.editingSession = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding()
        .frame(width: 500)
        .onAppear {
            sessionName = session.name
            projectDir = session.projectDir
            cbcSessionID = session.cbcSessionID ?? ""
            validateDir(projectDir)
        }
        .task(id: currentQuery) { await checkConversationLocation() }
    }

    /// Find out whether the typed directory is the one the bound conversation
    /// belongs to, so a resume that would fail ("No conversation found with
    /// session ID") is caught here instead.
    ///
    /// Debounced, and its result is stamped with the inputs it was asked for:
    /// the lookup is a network round trip, so what comes back may describe
    /// values the user has already typed past.
    private func checkConversationLocation() async {
        let query = currentQuery
        guard !query.cbcSessionID.isEmpty else {
            location = nil
            locationInputs = nil
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let found = await viewModel.conversationLocation(
            agent: session.agentType,
            cbcSessionID: query.cbcSessionID,
            projectDir: query.projectDir
        )
        guard !Task.isCancelled else { return }
        location = found
        locationInputs = query

        // Where the conversation's records say the agent worked. Asked using the
        // directory the file is actually in (not the one being typed, which by
        // definition does not hold it yet), so the answer describes the session
        // as it stands rather than as it is being edited.
        suggestedWorkDir = nil
        guard let located = found, located.found, located.matches == false,
              let actualDir = located.projectDir, !actualDir.isEmpty else { return }
        guard let work = await viewModel.sessionWorkDir(
            agent: session.agentType,
            projectDir: actualDir,
            sessionID: query.cbcSessionID
        ), work != query.projectDir else { return }
        guard !Task.isCancelled else { return }
        suggestedWorkDir = work
    }

    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select project directory"

        if panel.runModal() == .OK {
            projectDir = panel.url?.path ?? projectDir
            validateDir(projectDir)
        }
    }

    private func validateDir(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            dirExists = false
            showDirError = false
            return
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        var isDir: ObjCBool = false
        dirExists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
        showDirError = !dirExists
    }
}
