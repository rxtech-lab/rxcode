import SwiftUI
import RxCodeCore

// MARK: - Task costs

/// Popover listing the usage-limit cost of each measured task per provider,
/// with each provider's most and least expensive tasks called out.
struct RateLimitTaskCostPopover: View {
    @Environment(AppState.self) private var appState

    let providers: [AgentProvider]
    let range: UsageStatsRange

    @State private var summaries: [AgentProvider: RateLimitTaskCostSummary] = [:]
    @AppStorage("rateLimitTaskCostSortOrder") private var sortOrder: SortOrder = .mostRecent

    /// Tasks listed per provider.
    private static let maxTasksPerProvider = 10

    enum SortOrder: String, CaseIterable {
        case mostRecent
        case leastRecent
        case mostUsed
        case leastUsed

        var title: LocalizedStringKey {
            switch self {
            case .mostRecent: "Most recent"
            case .leastRecent: "Least recent"
            case .mostUsed: "Most used"
            case .leastUsed: "Least used"
            }
        }
    }

    private var isEmpty: Bool {
        summaries.values.allSatisfy(\.isEmpty)
    }

    /// The provider's first tasks in the chosen order. Cost is the 5-hour
    /// delta, or the 7-day delta for plans without a 5-hour limit;
    /// unmeasurable tasks sort last either way.
    private func rankedTasks(_ summary: RateLimitTaskCostSummary, provider: AgentProvider) -> [RateLimitTaskCostSnapshot] {
        let usesFiveHour = hasFiveHourLimit(provider, in: appState)
        func cost(_ task: RateLimitTaskCostSnapshot) -> Double? {
            usesFiveHour ? task.fiveHourDelta : task.sevenDayDelta
        }
        let sorted = summary.tasks.sorted { lhs, rhs in
            switch sortOrder {
            case .mostRecent:
                return lhs.endedAt > rhs.endedAt
            case .leastRecent:
                return lhs.endedAt < rhs.endedAt
            case .mostUsed, .leastUsed:
                switch (cost(lhs), cost(rhs)) {
                case let (l?, r?) where l != r:
                    return sortOrder == .mostUsed ? l > r : l < r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.endedAt > rhs.endedAt
                }
            }
        }
        return Array(sorted.prefix(Self.maxTasksPerProvider))
    }

    private var sortPicker: some View {
        HStack {
            Text("Showing up to \(Self.maxTasksPerProvider) tasks per provider")
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Spacer()
            Picker("Sort by", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .font(.system(size: 11))
        }
    }

    var body: some View {
        RateLimitPopoverScaffold(
            title: String(localized: "Limit cost per task"),
            subtitle: String(localized: "\(range.localizedLongTitle) · change in each limit between a task's start and finish.")
        ) {
            if isEmpty {
                emptyMessage("No measured tasks in this window yet.")
            } else {
                sortPicker
                ForEach(providers, id: \.self) { provider in
                    let summary = summaries[provider] ?? RateLimitTaskCostSummary()
                    if !summary.isEmpty {
                        ProviderTableSection(provider: provider, rows: rankedTasks(summary, provider: provider)) { task in
                            row(task, provider: provider, summary: summary)
                        }
                    }
                }
                RateLimitGlossary(entries: [
                    .init(term: "Row", detail: "One finished task: its chat, model, finish time and how long it ran."),
                    .init(term: "5h · 7d", detail: "Percentage points of the 5-hour and 7-day limits the task used, measured from its start to its finish."),
                    .init(term: "Most · Least", detail: "The provider's most and least expensive tasks in this window."),
                    .init(term: "—", detail: "The limit reset while the task ran, so its cost can't be measured."),
                    .init(term: "Ran with others", detail: "Tasks running at the same time share one limit, so their costs are approximate and are left out of the averages once enough solo tasks exist."),
                ])
            }
        }
        .task(id: appState.rateLimitHistoryRevision) {
            var result: [AgentProvider: RateLimitTaskCostSummary] = [:]
            for provider in providers {
                result[provider] = appState.rateLimitTaskCostSummary(for: provider, range: range)
            }
            summaries = result
        }
    }

    private func row(_ task: RateLimitTaskCostSnapshot, provider: AgentProvider, summary: RateLimitTaskCostSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.threadTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                    if task.id == summary.mostExpensive?.id {
                        badge("Most")
                            .help("The most expensive task in this window.")
                    } else if task.id == summary.leastExpensive?.id {
                        badge("Least")
                            .help("The least expensive task in this window.")
                    }
                }
                Text(subtitle(for: task, provider: provider))
                    .font(.system(size: 10.5))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if hasFiveHourLimit(provider, in: appState) {
                cost("5h used", task.fiveHourDelta)
            }
            cost("7d used", task.sevenDayDelta)
        }
    }

    private func subtitle(for task: RateLimitTaskCostSnapshot, provider: AgentProvider) -> String {
        var parts: [String] = []
        if !task.model.isEmpty {
            parts.append(appState.usageModelDisplayName(task.model, provider: provider))
        }
        parts.append(task.endedAt.formatted(date: .abbreviated, time: .shortened))
        parts.append(BriefingUsageStatsView.formatDuration(task.endedAt.timeIntervalSince(task.startedAt)))
        if task.concurrentRuns > 0 {
            parts.append(task.concurrentRuns == 1
                ? String(localized: "ran with 1 other task")
                : String(localized: "ran with \(task.concurrentRuns) other tasks"))
        }
        return parts.joined(separator: " · ")
    }

    private func cost(_ label: LocalizedStringKey, _ delta: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(BriefingRateLimitStatsView.formatOptionalDelta(delta))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .frame(width: 64, alignment: .trailing)
        .help(delta == nil
            ? String(localized: "The limit reset during this task, so its cost can't be measured.")
            : String(localized: "Percentage points of this limit the task used."))
    }

    private func badge(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(ClaudeTheme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(ClaudeTheme.accent.opacity(0.12)))
    }
}
