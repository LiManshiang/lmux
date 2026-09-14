import SwiftUI
import AppKit

/// General app settings. More options can be added here later.
struct GeneralSettingsView: View {
    private static let restoreKey = "lmux_restore_last_session"
    @AppStorage("lmux_restore_last_session") private var restoreLastSession = true

    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section(L("Startup")) {
                Toggle(L("Restore last selected session on launch"), isOn: $restoreLastSession)
                    .toggleStyle(.switch)

                Text(L("When enabled, lmux re-launches the agent you were using when the app last quit. Disable to always start with a fresh list."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Section(L("Appearance")) {
                Picker(L("Theme"), selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(L("Applies to lmux's own windows. The terminal keeps its own theme (see Settings → Terminal)."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Section(L("Language")) {
                Picker(L("Interface language"), selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(L("Takes effect after relaunching lmux — rebuilding the interface live would drop the terminal sessions."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Section(L("Behavior")) {
                Text(L("More general options will appear here as lmux grows."))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .formScrollable()
        .groupedForm()
    }
}
