import SwiftUI

/// Settings window: a sidebar of categories (Terminal / Sync / General /
/// About). New categories and options can be added by extending the TabView.
struct PreferencesView: View {
    var body: some View {
        TabView {
            TerminalSettingsView()
                .tabItem {
                    Label(L("Terminal"), systemImage: "terminal")
                }
            SyncSettingsView()
                .tabItem {
                    Label(L("Sync"), systemImage: "arrow.triangle.2.circlepath")
                }
            GeneralSettingsView()
                .tabItem {
                    Label(L("General"), systemImage: "gearshape")
                }
            AboutSettingsView()
                .tabItem {
                    Label(L("About"), systemImage: "info.circle")
                }
        }
        // Fill the host window so Form items use the full width. Fixed
        // 480x420 left large empty margins on macOS 12 (Form items
        // right-stack inside that frame, clipping the Browse button against
        // the window edge). Window content size is still set to 600x470 in
        // SettingsWindowController.
        .frame(minWidth: 480, idealWidth: 600, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
    }
}
