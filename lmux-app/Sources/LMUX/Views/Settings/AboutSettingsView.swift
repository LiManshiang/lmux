import SwiftUI
import AppKit

/// About: app identity, version and sync device id.
struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            AppIconView()
                .frame(width: 96, height: 96)

            Text("lmux")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(AppVersion.current)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 40)

            VStack(spacing: 6) {
                HStack {
                    Text("Agent")
                    Spacer()
                    Text("CodeBuddy / Claude")
                }
                HStack {
                    Text("Sync Device ID")
                    Spacer()
                    Text(SessionSync.deviceID)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 11))
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 20)

            Spacer()
        }
        .padding(.top, 24)
    }
}

/// Renders the real app icon (loaded from the bundle) at a given size.
private struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .interpolation(.high)
    }
}
