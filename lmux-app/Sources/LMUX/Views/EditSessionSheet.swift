import SwiftUI
import LMUXCore

/// Edit the editable fields of a stopped session: display name, project
/// directory, and the bound conversation ID.
struct EditSessionSheet: View {
    let session: SessionSummary
    @EnvironmentObject var viewModel: ContentViewModel

    @State private var sessionName = ""
    @State private var projectDir = ""
    @State private var cbcSessionID = ""
    @State private var dirExists = false
    @State private var showDirError = false

    private var hasChanges: Bool {
        sessionName != session.name
            || projectDir != session.projectDir
            || cbcSessionID != (session.cbcSessionID ?? "")
    }

    private var canSave: Bool {
        let trimmed = projectDir.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && dirExists && hasChanges
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Session")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Session name", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Project Directory")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("~/Projects/my-project", text: $projectDir)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: projectDir) { newValue in
                                validateDir(newValue)
                            }

                        Button("Browse…") {
                            browseDirectory()
                        }
                    }
                    if showDirError {
                        Text("Directory does not exist or is not accessible")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Session ID (cbc_session_id)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Conversation ID", text: $cbcSessionID)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") {
                    viewModel.editingSession = nil
                }

                Button("Save") {
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
            prefillWorkingDirectory()
        }
    }

    /// When the session has a bound conversation, prefill the project
    /// directory with the agent's actual working directory (the folder it
    /// last worked in), so edits reflect reality without hunting it down.
    private func prefillWorkingDirectory() {
        guard session.cbcSessionID?.isEmpty == false else { return }
        Task {
            guard let cwd = await viewModel.agentWorkingDir(for: session) else { return }
            await MainActor.run {
                projectDir = cwd
                validateDir(cwd)
            }
        }
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
