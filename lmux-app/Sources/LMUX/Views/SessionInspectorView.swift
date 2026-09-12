import SwiftUI
import LMUXCore

/// At-a-glance usage for one session: what its process is doing, what its
/// conversation has cost, and where it is working.
///
/// Every figure here is already gathered elsewhere — process stats come from
/// the TerminalManager that the terminal owns, and the conversation figures
/// reuse the same context query the sidebar rows make. Opening this pane adds
/// no new sampling.
struct SessionInspectorView: View {
    let session: SessionSummary
    /// nil when this session has no live terminal in this launch.
    let manager: TerminalManager?

    @EnvironmentObject var viewModel: ContentViewModel
    @State private var usage: ContextUsageInfo?

    /// Same cadence as the sidebar's context readout.
    private static let refreshInterval: UInt64 = 5_000_000_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                processSection
                conversationSection
                workspaceSection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: session.id) { await pollUsage() }
    }

    // MARK: - Sections

    private var processSection: some View {
        section("Process") {
            field("State", stateLabel, emphasised: true)
            field("CPU", cpuLabel)
            field("Memory", memoryLabel)
            field("Uptime", manager?.processRunning == true ? (manager?.formattedElapsed ?? "—") : "—")
            field("PID", (manager?.processPID ?? 0) > 0 ? String(manager!.processPID) : "—")
        }
    }

    private var conversationSection: some View {
        section("Conversation") {
            field("Agent", session.agentType.displayName)
            field("Model", usage?.model ?? "—")
            field("Context", contextLabel, emphasised: true)
            field("Tokens", usage.map { Self.formatCount($0.tokens) } ?? "—")
            field("Waiting", manager?.processRunning == true
                  ? (usage?.awaitingInput == true ? "yes" : "no")
                  : "—")
            if let cbc = session.cbcSessionID, !cbc.isEmpty {
                field("Session", String(cbc.prefix(8)) + "…")
                    .textSelection(.enabled)
            }
        }
    }

    private var workspaceSection: some View {
        section("Workspace") {
            field("Directory", manager?.currentWorkingDirectory ?? session.projectDir)
                .textSelection(.enabled)
            field("Branch", session.gitBranch?.isEmpty == false ? session.gitBranch! : "—")
        }
    }

    // MARK: - Labels

    private var stateLabel: String {
        guard let manager, manager.processRunning else { return "stopped" }
        return manager.isIdle ? "idle" : "running"
    }

    private var cpuLabel: String {
        guard let cpu = manager?.cpuPercent else { return manager?.processRunning == true ? "—" : "—" }
        return cpu < 1 ? "<1%" : String(format: "%.0f%%", cpu)
    }

    private var memoryLabel: String {
        guard let mem = manager?.memoryMB else { return "—" }
        return "\(Int(mem)) MB"
    }

    private var contextLabel: String {
        guard let usage, usage.contextWindow > 0 else { return "—" }
        let percent = Int((Double(usage.tokens) / Double(usage.contextWindow) * 100).rounded())
        return "\(percent)% of \(Self.formatCount(usage.contextWindow))"
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String, emphasised: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: emphasised ? .medium : .regular))
                .foregroundColor(emphasised ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Formatting

    /// 1_234 → "1.2k", 1_234_567 → "1.2M".
    private static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: - Polling

    private func pollUsage() async {
        // Resolve the conversation id the same way the row does: the recorded
        // binding, else whatever the running agent reported.
        let cbc = session.cbcSessionID?.isEmpty == false
            ? session.cbcSessionID
            : manager?.detectedCBCSessionID

        while !Task.isCancelled {
            if let cbc, !cbc.isEmpty {
                usage = await viewModel.agentContextUsage(
                    agent: session.agentType,
                    cbcSessionID: cbc,
                    projectDir: session.projectDir
                )
            }
            try? await Task.sleep(nanoseconds: Self.refreshInterval)
        }
    }
}
