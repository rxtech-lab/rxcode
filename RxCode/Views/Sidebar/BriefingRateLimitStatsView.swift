import SwiftUI
import RxCodeCore

/// Usage-limit tiles on the briefing page, comparing Claude Code and Codex
/// side by side: current 5-hour / 7-day limits (with their history), how much
/// of the limits a task costs, and how many more tasks fit. Uses the window
/// picked in the usage statistics header. Limits are account-wide, so the
/// briefing project filter doesn't apply.
struct BriefingRateLimitStatsView: View {
    @Environment(AppState.self) private var appState

    let range: UsageStatsRange

    @State private var summaries: [AgentProvider: RateLimitTaskCostSummary] = [:]
    @State private var activePopover: DetailPopover?

    private enum DetailPopover {
        case history
        case taskCosts
        case models
    }

    /// Providers with usage limits that are available on this Mac.
    private var providers: [AgentProvider] {
        AppState.rateLimitedProviders.filter { $0 != .codex || appState.codexInstalled }
    }

    private struct ReloadKey: Equatable {
        let providers: [AgentProvider]
        let range: UsageStatsRange
        let revision: Int
        let usages: [RateLimitUsage?]
    }

    private var reloadKey: ReloadKey {
        ReloadKey(
            providers: providers,
            range: range,
            revision: appState.rateLimitHistoryRevision,
            usages: providers.map { appState.cachedRateLimitUsage(for: $0) }
        )
    }

    private var hasTasks: Bool {
        summaries.values.contains { !$0.isEmpty }
    }

    /// Emits the tiles as separate children so the parent grid lays them out
    /// alongside its own tiles. The shared `.task` / `.sheet` hang off the
    /// first tile so they aren't duplicated per child.
    var body: some View {
        limitsTile
            .task(id: reloadKey) {
                var result: [AgentProvider: RateLimitTaskCostSummary] = [:]
                for provider in providers {
                    result[provider] = appState.rateLimitTaskCostSummary(for: provider, range: range)
                }
                summaries = result
            }
        taskCostTile
        remainingTile
    }

    /// Popover for `kind`, anchored to the tile that opened it.
    @ViewBuilder
    private func detailPopover(_ kind: DetailPopover) -> some View {
        switch kind {
        case .history:
            RateLimitHistoryPopover(providers: providers, range: range)
        case .taskCosts:
            RateLimitTaskCostPopover(providers: providers, range: range)
        case .models:
            RateLimitModelEstimatePopover(providers: providers, range: range)
        }
    }

    private func popoverBinding(_ kind: DetailPopover) -> Binding<Bool> {
        Binding(
            get: { activePopover == kind },
            set: { if !$0 { activePopover = nil } }
        )
    }

    // MARK: - Tiles

    private var limitsTile: some View {
        Button {
            activePopover = .history
        } label: {
            BriefingProviderStatTile(
                icon: "gauge.with.dots.needle.33percent",
                title: "Usage limits",
                rows: providers.map { provider in
                    let usage = appState.cachedRateLimitUsage(for: provider)
                    return .init(
                        id: provider.rawValue,
                        label: provider.displayNameText,
                        value: usage.map { usage in
                            usage.hasFiveHourLimit
                                ? "\(Self.formatPercent(usage.fiveHourPercent)) · \(Self.formatPercent(usage.sevenDayPercent))"
                                : Self.formatPercent(usage.sevenDayPercent)
                        } ?? "—",
                        detail: usage.flatMap(Self.resetDetail)
                    )
                },
                footnote: String(localized: "5-hour · 7-day used"),
                accessoryIcon: "chart.xyaxis.line",
                help: "Show the usage-limit history chart."
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: popoverBinding(.history), arrowEdge: .bottom) {
            detailPopover(.history)
        }
    }

    private var taskCostTile: some View {
        Button {
            activePopover = .taskCosts
        } label: {
            BriefingProviderStatTile(
                icon: "chart.bar.xaxis",
                title: "Limit cost per task",
                rows: providers.map { provider in
                    let summary = summaries[provider] ?? RateLimitTaskCostSummary()
                    let hasFiveHour = hasFiveHourLimit(provider)
                    return .init(
                        id: provider.rawValue,
                        label: provider.displayNameText,
                        value: summary.sampleCount > 0
                            ? (hasFiveHour
                                ? "\(Self.formatOptionalDelta(summary.averageFiveHour)) · \(Self.formatOptionalDelta(summary.averageSevenDay))"
                                : Self.formatOptionalDelta(summary.averageSevenDay))
                            : "—",
                        detail: Self.costDetail(summary, hasFiveHour: hasFiveHour)
                    )
                },
                footnote: String(localized: "Average of 5-hour · 7-day per task"),
                accessoryIcon: hasTasks ? "list.bullet" : nil,
                help: "Show the usage-limit cost of each task."
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: popoverBinding(.taskCosts), arrowEdge: .bottom) {
            detailPopover(.taskCosts)
        }
        .disabled(!hasTasks)
    }

    private var remainingTile: some View {
        Button {
            activePopover = .models
        } label: {
            BriefingProviderStatTile(
                icon: "hourglass",
                title: "Tasks remaining",
                rows: providers.map { provider in
                    let summary = summaries[provider] ?? RateLimitTaskCostSummary()
                    let hasUsage = appState.cachedRateLimitUsage(for: provider) != nil
                    return .init(
                        id: provider.rawValue,
                        label: provider.displayNameText,
                        value: hasUsage
                            ? (hasFiveHourLimit(provider)
                                ? String(localized: "5h \(Self.formatEstimate(summary.remainingFiveHour)) · 7d \(Self.formatEstimate(summary.remainingSevenDay))")
                                : String(localized: "7d \(Self.formatEstimate(summary.remainingSevenDay))"))
                            : "—",
                        detail: Self.basisDetail(summary)
                    )
                },
                footnote: String(localized: "Tasks left in 5-hour · 7-day limits"),
                accessoryIcon: hasTasks ? "list.bullet.rectangle" : nil,
                help: "Tasks of average cost that fit in what's left of each limit. Click for estimates by model."
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: popoverBinding(.models), arrowEdge: .bottom) {
            detailPopover(.models)
        }
        .disabled(!hasTasks)
    }

    /// False for plans without a separate 5-hour limit; their tiles show only
    /// the 7-day figures.
    private func hasFiveHourLimit(_ provider: AgentProvider) -> Bool {
        appState.cachedRateLimitUsage(for: provider)?.hasFiveHourLimit ?? true
    }

    private static func resetDetail(_ usage: RateLimitUsage) -> String? {
        if usage.hasFiveHourLimit {
            return usage.fiveHourResetsAt.map {
                String(localized: "5-hour resets \($0.formatted(.relative(presentation: .named)))")
            }
        }
        return usage.sevenDayResetsAt.map {
            String(localized: "7-day resets \($0.formatted(.relative(presentation: .named)))")
        }
    }

    private static func costDetail(_ summary: RateLimitTaskCostSummary, hasFiveHour: Bool) -> String {
        guard summary.sampleCount > 0 else { return String(localized: "No measured tasks yet") }
        let delta = hasFiveHour ? \RateLimitTaskCostSnapshot.fiveHourDelta : \RateLimitTaskCostSnapshot.sevenDayDelta
        let most = summary.mostExpensive?[keyPath: delta].map(formatDelta)
        let least = summary.leastExpensive?[keyPath: delta].map(formatDelta)
        switch (most, least, hasFiveHour) {
        case let (most?, least?, true): return String(localized: "5h most \(most) · least \(least)")
        case let (most?, nil, true): return String(localized: "5h most \(most)")
        case let (most?, least?, false): return String(localized: "7d most \(most) · least \(least)")
        case let (most?, nil, false): return String(localized: "7d most \(most)")
        default:
            return summary.sampleCount == 1
                ? String(localized: "1 task measured")
                : String(localized: "\(summary.sampleCount) tasks measured")
        }
    }

    private static func basisDetail(_ summary: RateLimitTaskCostSummary) -> String {
        let count = summary.sampleCount
        guard count > 0 else { return String(localized: "Estimates appear after tasks finish") }
        switch (count == 1, summary.usesIsolatedSamplesOnly) {
        case (true, true): return String(localized: "Based on 1 task run alone")
        case (true, false): return String(localized: "Based on 1 task")
        case (false, true): return String(localized: "Based on \(count) tasks run alone")
        case (false, false): return String(localized: "Based on \(count) tasks")
        }
    }

    // MARK: - Formatting

    static func formatPercent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }

    /// Percentage points of a limit, e.g. `1.5%`.
    static func formatDelta(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }

    static func formatOptionalDelta(_ value: Double?) -> String {
        value.map(formatDelta) ?? "—"
    }

    /// Remaining tasks with their unit, e.g. `~63 tasks`.
    static func formatEstimate(_ estimate: RateLimitTaskCostSummary.Estimate) -> String {
        switch estimate {
        case .insufficientData: "—"
        case .unbounded: String(localized: "Many")
        case .tasks(1): String(localized: "~1 task")
        case .tasks(let count): String(localized: "~\(count) tasks")
        }
    }
}
