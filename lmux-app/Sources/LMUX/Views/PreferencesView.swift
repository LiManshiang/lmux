import SwiftUI

struct PreferencesView: View {
    @AppStorage("terminalTheme") private var selectedThemeId = "dracula"
    @AppStorage(TerminalRendererSetting.key) private var selectedRenderer = TerminalRendererSetting.swiftterm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Terminal Renderer")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker("Renderer", selection: $selectedRenderer) {
                    Text("SwiftTerm").tag(TerminalRendererSetting.swiftterm)
                    Text("Ghostty (libghostty)").tag(TerminalRendererSetting.ghostty)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("Rendering engine. Ghostty uses GPU-accelerated Metal rendering (macOS 13+). Changes apply to newly connected sessions.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Text("Terminal Theme")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            List(TerminalTheme.all) { theme in
                HStack(spacing: 10) {
                    themePreview(theme)
                    Text(theme.name)
                        .font(.system(size: 13))
                    Spacer()
                    if selectedThemeId == theme.id {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedThemeId = theme.id
                    // Apply the theme live to running terminals.
                    NotificationCenter.default.post(
                        name: .lmuxTerminalThemeChanged,
                        object: nil,
                        userInfo: ["themeId": theme.id]
                    )
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 380, height: 420)
    }

    @ViewBuilder
    private func themePreview(_ theme: TerminalTheme) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: theme.backgroundNSColor)).frame(width: 16, height: 16)
            Rectangle().fill(Color(nsColor: theme.foregroundNSColor)).frame(width: 16, height: 16)
            Rectangle().fill(Color(nsColor: theme.cursorNSColor)).frame(width: 4, height: 16)
            Rectangle().fill(Color(nsColor: theme.selectionNSColor)).frame(width: 4, height: 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
    }
}
