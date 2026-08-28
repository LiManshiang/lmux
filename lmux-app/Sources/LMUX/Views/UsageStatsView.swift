import SwiftUI

/// Usage statistics panel: per-session context usage, model and estimated
/// credit, sorted by credit descending so the most expensive sessions are
/// at the top.
struct UsageStatsView: View {
    @EnvironmentObject var viewModel: ContentViewModel
    @State private var sortOrder: SortOrder = .credit
    @State private var showOnlyAgent = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case credit
        case tokens
        case percent
        case name
        var id: String { rawValue }

        var label: String {
            switch self {
            case .credit: return "积分"
            case .tokens: return "Token"
            case .percent: return "上下文"
            case .name: return "名称"
            }
        }
    }

    private var sorted: [SessionUsageStat] {
        var list = viewModel.usageStats
        if showOnlyAgent {
            list = list.filter { $0.tokens > 0 }
        }
        switch sortOrder {
        case .credit: list.sort { $0.credit > $1.credit }
        case .tokens: list.sort { $0.tokens > $1.tokens }
        case .percent: list.sort { $0.percent > $1.percent }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("会话使用统计")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    Task { await viewModel.loadUsageStats() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.usageStatsLoading)
                Button {
                    viewModel.showUsageStats = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 12) {
                Picker("排序", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Toggle("仅 Agent 会话", isOn: $showOnlyAgent)
                    .font(.system(size: 11))
                    .toggleStyle(.checkbox)

                Spacer()

                if viewModel.usageStatsLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            if viewModel.usageStats.isEmpty && !viewModel.usageStatsLoading {
                Spacer()
                Text("无数据")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(sorted) { stat in
                            UsageStatsRow(stat: stat)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .frame(width: 560, height: 420)
        .task {
            await viewModel.loadUsageStats()
        }
    }
}

private struct UsageStatsRow: View {
    let stat: SessionUsageStat

    private var percentColor: Color {
        if stat.percent >= 90 { return .red }
        if stat.percent >= 80 { return .orange }
        return .secondary
    }

    private var agentLabel: String {
        stat.agentType == "claude" ? "Claude" : "CodeBuddy"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stat.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(stat.model?.isEmpty == false ? "\(agentLabel) · \(stat.model!)" : agentLabel)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Context progress bar.
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(stat.percent, specifier: "%.1f")%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(percentColor)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(percentColor)
                            .frame(width: geo.size.width * CGFloat(min(stat.percent, 100) / 100))
                    }
                }
                .frame(height: 4)
            }
            .frame(width: 90)

            // Tokens.
            Text(formattedTokens(stat.tokens))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)

            // Credit.
            Text(String(format: "%.2f", stat.credit))
                .font(.system(size: 11))
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    private func formattedTokens(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
