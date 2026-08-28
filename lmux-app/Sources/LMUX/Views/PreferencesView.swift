import SwiftUI

/// Settings window: a sidebar of categories (Terminal / Sync / General /
/// About). New categories and options can be added by extending the TabView.
struct PreferencesView: View {
    var body: some View {
        TabView {
            TerminalSettingsView()
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }
            SyncSettingsView()
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 420)
    }
}
