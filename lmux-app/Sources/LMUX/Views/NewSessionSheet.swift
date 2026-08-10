import SwiftUI
import LMUXCore

struct NewSessionSheet: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var projectDir = ""
    @State private var sessionName = ""
    @State private var cbcSessionID = ""
    @State private var useResume = false
    @State private var agentType: AgentType = .codebuddy
    @State private var dirExists = false
    @State private var showDirError = false

    private var canCreate: Bool {
        let trimmed = projectDir.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && dirExists
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("New Session")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
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

                        Button("Browse...") {
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
                    Text("Session Name (optional)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Auto-generated from project name", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Agent", selection: $agentType) {
                        ForEach(AgentType.allCases, id: \.self) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Toggle(isOn: $useResume) {
                    Text("Resume existing session")
                        .font(.body)
                }

                if useResume {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("UUID", text: $cbcSessionID)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack(spacing: 12) {
                Spacer()

                Button("Cancel") {
                    viewModel.showNewSessionSheet = false
                }

                Button("Create") {
                    let dir = projectDir.trimmingCharacters(in: .whitespaces)
                    let name = sessionName.trimmingCharacters(in: .whitespaces)
                    let cbc = useResume ? cbcSessionID.trimmingCharacters(in: .whitespaces) : nil
                    let finalName = name.isEmpty ? nil : name

                    Task {
                        await viewModel.createSession(
                            projectDir: dir,
                            name: finalName,
                            cbcSessionID: cbc,
                            agentType: agentType
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)
            }
        }
        .padding()
        .frame(width: 500)
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
