import SwiftUI
import RxCodeCore

/// Usage statistics panel on the briefing page: most used model/provider,
/// session time, and tokens for a pickable window. Reads the persisted,
/// pre-aggregated `UsageStatBucket` rows, so opening the page never rescans
/// thread history.
struct BriefingUsageStatsView: View {
    @Environment(AppState.self) private var appState

    /// Project filter from the briefing filter bar. Empty = every project.
    let projectIds: Set<UUID>

    @AppStorage("briefingUsageStatsRange") private var rangeRaw: String = UsageStatsRange.week.rawValue
    @State private var summary = UsageStatsSummary()
    @State private var activePopover: BreakdownPopover?

    private var range: UsageStatsRange {
        UsageStatsRange(rawValue: rangeRaw) ?? .week
    }

    private struct ReloadKey: Equatable {
        let range: UsageStatsRange
        let revision: Int
        let projectIds: Set<UUID>
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                modelTile
                sessionTimeTile
                tokensTile
                // Claude Code / Codex usage limits share this panel's window
                // picker and wrap in the same row as the usage tiles.
                BriefingRateLimitStatsView(range: range)
            }
        }
        .task(id: ReloadKey(range: range, revision: appState.usageStatsRevision, projectIds: projectIds)) {
            summary = appState.usageSummary(range: range, projectIds: projectIds)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Usage")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            rangeMenu
            Spacer(minLength: 0)
        }
    }

    /// Dropdown button for the time window, styled like the briefing hero's
    /// Autopilot menu.
    private var rangeMenu: some View {
        BriefingPanelMenu(
            options: UsageStatsRange.allCases,
            selection: range,
            title: \.localizedLongTitle,
            help: "Choose the time window for usage statistics."
        ) { rangeRaw = $0.rawValue }
    }

    // MARK: - Tiles

    private enum BreakdownPopover {
        case models
        case sessionTime
        case tokens
    }

    private var modelTile: some View {
        let top = summary.topModel
        let provider = summary.topProvider
        let providerName = provider.flatMap { AgentProvider(rawValue: $0.providerRaw)?.displayNameText }
        return breakdownTile(.models) {
            tile(
                icon: "cpu",
                title: "Most used model",
                value: top.map { modelName($0) } ?? "—",
                detail: top.map { usage in
                    let providerLabel = AgentProvider(rawValue: usage.providerRaw)?.displayNameText ?? usage.providerRaw
                    return String(localized: "\(providerLabel) · \(share(usage.turns)) of turns")
                } ?? String(localized: "No agent turns yet"),
                footnote: providerName.map { name in
                    String(localized: "Top provider: \(name) (\(share(provider?.turns ?? 0)))")
                },
                isInteractive: !summary.isEmpty,
                help: "Show the model and provider breakdown."
            )
        } popover: {
            UsageBreakdownPopover(
                title: String(localized: "Model usage"),
                subtitle: String(localized: "\(range.localizedLongTitle) · share of \(Self.formatTurns(summary.turns))"),
                charts: [
                    .init(title: String(localized: "By model"), unit: String(localized: "turns"), slices: modelSlices),
                    .init(title: String(localized: "By provider"), unit: String(localized: "turns"), slices: providerSlices),
                ]
            )
        }
    }

    private var sessionTimeTile: some View {
        breakdownTile(.sessionTime) {
            tile(
                icon: "clock",
                title: "Session time",
                value: summary.isEmpty ? "—" : Self.formatDuration(summary.sessionSeconds),
                detail: summary.isEmpty
                    ? String(localized: "No agent turns yet")
                    : Self.formatTurns(summary.turns),
                footnote: summary.isEmpty
                    ? nil
                    : String(localized: "Avg \(Self.formatDuration(summary.sessionSeconds / Double(summary.turns))) per turn"),
                isInteractive: !summary.isEmpty,
                help: "Show session time by provider and model."
            )
        } popover: {
            UsageBreakdownPopover(
                title: String(localized: "Session time"),
                subtitle: String(localized: "\(range.localizedLongTitle) · \(Self.formatDuration(summary.sessionSeconds)) of agent work"),
                charts: [
                    .init(title: String(localized: "By provider"), unit: String(localized: "time"), slices: providerTimeSlices, format: Self.formatDuration),
                    .init(title: String(localized: "By model"), unit: String(localized: "time"), slices: modelTimeSlices, format: Self.formatDuration),
                ]
            )
        }
    }

    private var tokensTile: some View {
        breakdownTile(.tokens) {
            tile(
                icon: "flame",
                title: "Tokens burned",
                value: summary.isEmpty ? "—" : Self.formatTokens(summary.totalTokens),
                detail: summary.isEmpty
                    ? String(localized: "No agent turns yet")
                    : String(localized: "\(Self.formatTokens(summary.inputTokens)) in · \(Self.formatTokens(summary.outputTokens)) out"),
                footnote: summary.isEmpty
                    ? nil
                    : String(localized: "\(Self.formatTokens(summary.cacheReadTokens + summary.cacheCreationTokens)) cache"),
                isInteractive: !summary.isEmpty,
                help: "Show the token breakdown."
            )
        } popover: {
            UsageBreakdownPopover(
                title: String(localized: "Token usage"),
                subtitle: String(localized: "\(range.localizedLongTitle) · \(summary.totalTokens.formatted()) tokens"),
                charts: [
                    .init(title: String(localized: "By type"), unit: String(localized: "tokens"), slices: tokenTypeSlices),
                    .init(title: String(localized: "By model"), unit: String(localized: "tokens"), slices: modelTokenSlices),
                ]
            )
        }
    }

    /// Wraps a tile in a button that opens its breakdown popover.
    private func breakdownTile<Tile: View, Popover: View>(
        _ kind: BreakdownPopover,
        @ViewBuilder tile: () -> Tile,
        @ViewBuilder popover: @escaping () -> Popover
    ) -> some View {
        Button {
            activePopover = kind
        } label: {
            tile()
        }
        .buttonStyle(.plain)
        .disabled(summary.isEmpty)
        .popover(
            isPresented: Binding(
                get: { activePopover == kind },
                set: { if !$0 { activePopover = nil } }
            ),
            arrowEdge: .bottom
        ) {
            popover()
        }
    }

    private func tile(
        icon: String,
        title: LocalizedStringKey,
        value: String,
        detail: String,
        footnote: String?,
        isInteractive: Bool,
        help: LocalizedStringKey
    ) -> some View {
        BriefingStatTile(
            icon: icon,
            title: title,
            value: value,
            detail: detail,
            footnote: footnote,
            accessoryIcon: isInteractive ? "chart.pie" : nil,
            help: help
        )
    }

    // MARK: - Breakdown slices

    private var modelSlices: [UsageBreakdownPopover.Slice] {
        UsageBreakdownPopover.Slice.folded(summary.models.map { usage in
            let provider = AgentProvider(rawValue: usage.providerRaw)?.displayNameText ?? usage.providerRaw
            return (id: usage.id, label: modelName(usage), detail: provider, value: Double(usage.turns))
        })
    }

    private var providerSlices: [UsageBreakdownPopover.Slice] {
        UsageBreakdownPopover.Slice.folded(summary.providers.map { usage in
            let name = AgentProvider(rawValue: usage.providerRaw)?.displayNameText ?? usage.providerRaw
            return (id: usage.providerRaw, label: name, detail: nil, value: Double(usage.turns))
        })
    }

    private var providerTimeSlices: [UsageBreakdownPopover.Slice] {
        let providers = summary.providers.sorted { $0.sessionSeconds > $1.sessionSeconds }
        return UsageBreakdownPopover.Slice.folded(providers.map { usage in
            let name = AgentProvider(rawValue: usage.providerRaw)?.displayNameText ?? usage.providerRaw
            return (id: usage.providerRaw, label: name, detail: nil, value: usage.sessionSeconds)
        })
    }

    private var modelTimeSlices: [UsageBreakdownPopover.Slice] {
        let models = summary.models.sorted { $0.sessionSeconds > $1.sessionSeconds }
        return UsageBreakdownPopover.Slice.folded(models.map { usage in
            let provider = AgentProvider(rawValue: usage.providerRaw)?.displayNameText ?? usage.providerRaw
            return (id: usage.id, label: modelName(usage), detail: provider, value: usage.sessionSeconds)
        })
    }

    private var tokenTypeSlices: [UsageBreakdownPopover.Slice] {
        UsageBreakdownPopover.Slice.folded([
            (id: "input", label: String(localized: "Input"), detail: nil, value: Double(summary.inputTokens)),
            (id: "output", label: String(localized: "Output"), detail: nil, value: Double(summary.outputTokens)),
            (id: "cacheRead", label: String(localized: "Cache read"), detail: nil, value: Double(summary.cacheReadTokens)),
            (id: "cacheWrite", label: String(localized: "Cache write"), detail: nil, value: Double(summary.cacheCreationTokens)),
        ], sorted: false)
    }

    private var modelTokenSlices: [UsageBreakdownPopover.Slice] {
        let models = summary.models.sorted { $0.totalTokens > $1.totalTokens }
        return UsageBreakdownPopover.Slice.folded(models.map { usage in
            let provider = AgentProvider(rawValue: usage.providerRaw)?.displayNameText ?? usage.providerRaw
            return (id: usage.id, label: modelName(usage), detail: provider, value: Double(usage.totalTokens))
        })
    }

    // MARK: - Formatting

    private func modelName(_ usage: UsageStatsSummary.Usage) -> String {
        let provider = AgentProvider(rawValue: usage.providerRaw) ?? .claudeCode
        return appState.usageModelDisplayName(usage.model, provider: provider)
    }

    private func share(_ turns: Int) -> String {
        guard summary.turns > 0 else { return "0%" }
        return (Double(turns) / Double(summary.turns)).formatted(.percent.precision(.fractionLength(0)))
    }

    static func formatTurns(_ count: Int) -> String {
        count == 1 ? String(localized: "1 turn") : String(localized: "\(count) turns")
    }

    static func formatDuration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 60 ? [.day, .hour, .minute] : [.second]
        return formatter.string(from: max(0, seconds)) ?? "0s"
    }

    static func formatTokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

extension UsageStatsRange {
    /// `longTitle` localized for display; the core package only has English.
    var localizedLongTitle: String {
        switch self {
        case .day: String(localized: "Last 24 hours")
        case .week: String(localized: "Last 7 days")
        case .month: String(localized: "Last 30 days")
        case .year: String(localized: "Last 365 days")
        }
    }
}
