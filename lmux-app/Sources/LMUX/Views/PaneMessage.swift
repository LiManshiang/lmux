import SwiftUI

/// A failure shown inside a pane: icon, message, optional second line, optional
/// retry. Written once because the browser, its search results and the preview
/// each hand-rolled the same block.
struct PaneMessage: View {
    let icon: String
    let title: String
    var detail: String?
    var retryTitle: String = "Retry"
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(.orange)
            Text(title)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let retry {
                Button(retryTitle, action: retry)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
