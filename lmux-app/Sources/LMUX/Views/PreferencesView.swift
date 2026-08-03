import SwiftUI

struct PreferencesView: View {
    @AppStorage("terminalTheme") private var selectedThemeId = "dracula"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .onTapGesture { selectedThemeId = theme.id }
            }
            .listStyle(.plain)
        }
        .frame(width: 360, height: 340)
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
