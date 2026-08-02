import SwiftUI

struct NewSessionSheet: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var projectDir = ""
    @State private var sessionName = ""
    @State private var cbcSessionID = ""
    @State private var useResume = false

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

                        Button("Browse...") {
                            browseDirectory()
                        }
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

                Toggle(isOn: $useResume) {
                    Text("Resume existing CodeBuddy session")
                        .font(.body)
                }

                if useResume {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CodeBuddy Session ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("UUID from ~/.codebuddy/projects/", text: $cbcSessionID)
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
                            cbcSessionID: cbc
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(projectDir.trimmingCharacters(in: .whitespaces).isEmpty)
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
        }
    }
}
