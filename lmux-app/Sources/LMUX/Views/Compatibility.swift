import SwiftUI

/// macOS 12 fallbacks for SwiftUI APIs that are macOS 13+ only.
///
/// The SwiftTerm (`lmux-st.app`) variant is built with a macOS 12 deployment
/// target, so 13+ APIs must degrade gracefully. The ghostty build (macOS 13+)
/// keeps the native look via `if #available`.
extension View {
    /// `.formStyle(.grouped)` is macOS 13+; macOS 12 gets the default style.
    func groupedForm() -> some View {
        if #available(macOS 13.0, *) {
            return AnyView(formStyle(.grouped))
        } else {
            return AnyView(self)
        }
    }
}

/// macOS 13+ `LabeledContent`; on macOS 12 render as a label + trailing row.
@available(macOS 10.15, *)
struct CompatLabeledContent<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 13.0, *) {
            LabeledContent(title) { content() }
        } else {
            HStack {
                Text(title)
                Spacer()
                content()
            }
        }
    }
}
