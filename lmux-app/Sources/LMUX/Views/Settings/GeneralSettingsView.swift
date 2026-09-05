import SwiftUI
import AppKit

/// General app settings. More options can be added here later.
struct GeneralSettingsView: View {
    private static let restoreKey = "lmux_restore_last_session"
    @AppStorage("lmux_restore_last_session") private var restoreLastSession = true

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Restore last selected session on launch", isOn: $restoreLastSession)
                    .toggleStyle(.switch)

                Text("When enabled, lmux re-launches the agent you were using when the app last quit. Disable to always start with a fresh list.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Section("Behavior") {
                Text("More general options will appear here as lmux grows.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .groupedForm()
    }
}
