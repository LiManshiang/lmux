import SwiftUI

/// Chrome for borderless icon buttons.
///
/// `.buttonStyle(.plain)` drops the system's hover highlight, so these buttons
/// used to give no feedback at all — and their hit area was just the glyph
/// (about 10pt). This adds a small hover wash, a focus ring-free hit area big
/// enough to click, and keeps the icon's own colours untouched.
private struct IconButtonChrome: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(3)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0))
            )
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Hover highlight + a comfortable hit area for borderless icon buttons.
    func iconButtonChrome() -> some View {
        modifier(IconButtonChrome())
    }
}
