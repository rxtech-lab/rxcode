import Charts
import SwiftUI
import RxCodeCore

// MARK: - Model estimates

/// Popover with limit cost and remaining-task estimates per model for every
/// provider, plus advice for the model each provider would run next.
struct RateLimitModelEstimatePopover: View {
    @Environment(AppState.self) private var appState

    let providers: [AgentProvider]
    let range: UsageStatsRange

    @State private var summaries: [AgentProvider: RateLimitTaskCostSummary] = [:]
    @State private var weeklyCosts: [AgentProvider: [RateLimitWeeklyCost]] = [:]

    private var isEmpty: Bool {
        summaries.values.allSatisfy { $0.models.isEmpty }
    }

    /// The model advice is given for: the selected model when the provider is
    /// selected, otherwise its most recently used model.
    private func focusModel(for provider: AgentProvider) -> String? {
        if appState.selectedAgentProvider == provider { return appState.selectedModel }
        return summaries[provider]?.tasks.first?.model
    }

    /// Model drawing down the limit fastest per token, when it's comparable.
    private func highestTierModel(_ summary: RateLimitTaskCostSummary) -> String? {
        let rated = summary.models.filter { $0.fiveHourPerMillionTokens != nil }
        guard rated.count > 1 else { return nil }
        return rated.max { ($0.fiveHourPerMillionTokens ?? 0) < ($1.fiveHourPerMillionTokens ?? 0) }?.model
    }

    var body: some View {
        RateLimitPopoverScaffold(
            title: String(localized: "Estimates by model"),
            subtitle: String(localized: "\(range.localizedLongTitle) · tasks of each model's average cost that fit in what's left of each limit.")
        ) {
            ForEach(providers, id: \.self) { provider in
                if let advice = appState.rateLimitAdvice(for: provider, model: focusModel(for: provider)) {
                    adviceCard(advice, provider: provider)
                }
            }

            if isEmpty {
                emptyMessage("No measured tasks in this window yet.")
            } else {
                ForEach(providers, id: \.self) { provider in
                    let summary = summaries[provider] ?? RateLimitTaskCostSummary()
                    if !summary.models.isEmpty {
                        let topTier = highestTierModel(summary)
                        ProviderTableSection(provider: provider, rows: summary.models) { stats in
                            row(stats, provider: provider, isHighestTier: stats.model == topTier)
                        }
                    }
                }
                if !perMillionBars.isEmpty {
                    perMillionChart
                }
                RateLimitGlossary(entries: [
                    .init(term: "5h / task", detail: "Average share of the 5-hour limit one task of this model uses. Plans without a 5-hour limit show 7d / task instead."),
                    .init(term: "Left in 5h · 7d", detail: "How many more tasks of that average cost fit before each limit is reached, based on what's used now."),
                    .init(term: "Many", detail: "Tasks so far barely moved the limit, so there's no practical cap yet."),
                    .init(term: "—", detail: "Not enough measured tasks to estimate."),
                    .init(term: "Highest tier", detail: "The model that uses the most limit for the same number of tokens."),
                    .init(term: "Per 1M tokens", detail: "Share of each limit a million tokens uses. Tokens are input and output tokens, including cache writes; cache reads aren't counted. Larger models cost more for the same tokens; for light tasks a cheaper model usually does the job and leaves more room. 0% means the limit didn't move, which is common for the 7-day limit."),
                ])
            }
            if !weeklyPoints.isEmpty {
                weeklyChart
            }
        }
        .task(id: appState.rateLimitHistoryRevision) {
            var result: [AgentProvider: RateLimitTaskCostSummary] = [:]
            var weekly: [AgentProvider: [RateLimitWeeklyCost]] = [:]
            for provider in providers {
                result[provider] = appState.rateLimitTaskCostSummary(for: provider, range: range)
                weekly[provider] = appState.rateLimitWeeklyCosts(for: provider)
            }
            summaries = result
            weeklyCosts = weekly
        }
    }

    private func adviceCard(_ advice: RateLimitAdvice, provider: AgentProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: advice.severity == .warning ? "exclamationmark.triangle.fill" : "lightbulb")
                    .foregroundStyle(advice.severity == .warning ? ClaudeTheme.statusWarning : ClaudeTheme.accent)
                Text(focusModel(for: provider).map { "\(provider.displayNameText) · \(appState.usageModelDisplayName($0, provider: provider))" }
                    ?? provider.displayNameText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
            }
            ForEach(advice.reasons, id: \.self) { reason in
                Text(reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(advice.suggestions) { suggestion in
                Text("• \(suggestion.title) — \(suggestion.detail)")
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous)
                .fill(ClaudeTheme.surfaceSecondary)
        )
    }

    private func row(_ stats: RateLimitTaskCostSummary.ModelStats, provider: AgentProvider, isHighestTier: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(modelLabel(stats, provider: provider))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)
                    if isHighestTier {
                        Text("Highest tier")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(ClaudeTheme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(ClaudeTheme.accent.opacity(0.12)))
                    }
                }
                Text(subtitle(for: stats))
                    .font(.system(size: 10.5))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if hasFiveHourLimit(provider, in: appState) {
                column("5h / task", BriefingRateLimitStatsView.formatOptionalDelta(stats.averageFiveHour),
                       help: "Average share of the 5-hour limit one task uses.")
                column("Left in 5h", BriefingRateLimitStatsView.formatEstimate(stats.remainingFiveHour),
                       help: "Tasks of average cost that still fit in the 5-hour limit.")
            } else {
                column("7d / task", BriefingRateLimitStatsView.formatOptionalDelta(stats.averageSevenDay),
                       help: "Average share of the 7-day limit one task uses.")
            }
            column("Left in 7d", BriefingRateLimitStatsView.formatEstimate(stats.remainingSevenDay),
                   help: "Tasks of average cost that still fit in the 7-day limit.")
        }
    }

    private func subtitle(for stats: RateLimitTaskCostSummary.ModelStats) -> String {
        var parts = [stats.sampleCount == 1 ? String(localized: "1 task") : String(localized: "\(stats.sampleCount) tasks")]
        if stats.medianTokens > 0 {
            parts.append(String(localized: "median \(BriefingUsageStatsView.formatTokens(Int(stats.medianTokens))) tokens"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Cost per million tokens

    private struct PerMillionBar: Identifiable {
        let provider: AgentProvider
        let model: String
        let window: String
        let value: Double
        var id: String { "\(provider.rawValue)|\(model)|\(window)" }
    }

    /// One bar per model and limit: percentage points of the limit that a
    /// million tokens cost.
    private var perMillionBars: [PerMillionBar] {
        let fiveHour = String(localized: "5-hour limit")
        let sevenDay = String(localized: "7-day limit")
        return providers.flatMap { provider in
            let hasFiveHour = hasFiveHourLimit(provider, in: appState)
            return (summaries[provider]?.models ?? []).flatMap { stats -> [PerMillionBar] in
                let model = modelLabel(stats, provider: provider)
                var bars: [PerMillionBar] = []
                if hasFiveHour, let value = stats.fiveHourPerMillionTokens {
                    bars.append(PerMillionBar(provider: provider, model: model, window: fiveHour, value: value))
                }
                if let value = stats.sevenDayPerMillionTokens {
                    bars.append(PerMillionBar(provider: provider, model: model, window: sevenDay, value: value))
                }
                return bars
            }
        }
    }

    private var perMillionChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Limit used per 1M tokens")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            Text("Counts input and output tokens, including cache writes. Cache reads are left out because they barely count toward limits.")
                .font(.system(size: 10.5))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Chart(perMillionBars) { bar in
                BarMark(
                    x: .value("Limit used", bar.value),
                    y: .value("Model", bar.model)
                )
                .foregroundStyle(by: .value("Limit", bar.window))
                .position(by: .value("Limit", bar.window))
                .annotation(position: .trailing, spacing: 4) {
                    Text(BriefingRateLimitStatsView.formatDelta(bar.value))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
            }
            .chartForegroundStyleScale(
                domain: [String(localized: "5-hour limit"), String(localized: "7-day limit")],
                range: [UsageBreakdownPopover.Slice.palette[0], UsageBreakdownPopover.Slice.palette[2]]
            )
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text(BriefingRateLimitStatsView.formatDelta(percent))
                        }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: CGFloat(max(Set(perMillionBars.map(\.model)).count, 1)) * 44 + 40)
        }
    }

    // MARK: - Weekly trend

    private struct WeeklyPoint: Identifiable {
        let provider: AgentProvider
        let isFiveHour: Bool
        let week: RateLimitWeeklyCost
        let value: Double
        var id: String { "\(provider.rawValue)|\(isFiveHour)|\(week.weekStart.timeIntervalSince1970)" }
    }

    /// One point per provider, limit and week.
    private var weeklyPoints: [WeeklyPoint] {
        providers.flatMap { provider in
            let hasFiveHour = hasFiveHourLimit(provider, in: appState)
            return (weeklyCosts[provider] ?? []).flatMap { week -> [WeeklyPoint] in
                var points: [WeeklyPoint] = []
                if hasFiveHour, let value = week.fiveHourPerMillionTokens {
                    points.append(WeeklyPoint(provider: provider, isFiveHour: true, week: week, value: value))
                }
                if let value = week.sevenDayPerMillionTokens {
                    points.append(WeeklyPoint(provider: provider, isFiveHour: false, week: week, value: value))
                }
                return points
            }
        }
    }

    private var weeklyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Limit used per 1M tokens by week")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            Text("Last 12 weeks, regardless of the window picked above. A rising line means the same tokens cost more of the limit than before. Solid lines are 5-hour limits, dashed lines 7-day limits.")
                .font(.system(size: 10.5))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Chart(weeklyPoints) { point in
                LineMark(
                    x: .value("Week", point.week.weekStart, unit: .weekOfYear),
                    y: .value("Limit used", point.value),
                    series: .value("Series", "\(point.provider.rawValue) \(point.isFiveHour)")
                )
                .foregroundStyle(by: .value("Provider", point.provider.displayNameText))
                .lineStyle(point.isFiveHour
                    ? StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    : StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                PointMark(
                    x: .value("Week", point.week.weekStart, unit: .weekOfYear),
                    y: .value("Limit used", point.value)
                )
                .foregroundStyle(by: .value("Provider", point.provider.displayNameText))
                .symbolSize(24)
            }
            .chartForegroundStyleScale(
                domain: providers.map(\.displayNameText),
                range: providers.map(providerColor)
            )
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text(BriefingRateLimitStatsView.formatDelta(percent))
                        }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .leading)
            .frame(height: 200)
        }
    }

    private func modelLabel(_ stats: RateLimitTaskCostSummary.ModelStats, provider: AgentProvider) -> String {
        stats.model.isEmpty ? String(localized: "Default") : appState.usageModelDisplayName(stats.model, provider: provider)
    }

    private func column(_ label: LocalizedStringKey, _ value: String, help: LocalizedStringKey) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(ClaudeTheme.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(ClaudeTheme.textTertiary)
        }
        .frame(width: 84, alignment: .trailing)
        .help(help)
    }
}
