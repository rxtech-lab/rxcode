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
        Menu {
            ForEach(UsageStatsRange.allCases) { option in
                Button {
                    rangeRaw = option.rawValue
                } label: {
                    if option == range {
                        Label(option.longTitle, systemImage: "checkmark")
                    } else {
                        Text(option.longTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(range.longTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(ClaudeTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(ClaudeTheme.surfaceSecondary)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the time window for usage statistics.")
    }

    // MARK: - Tiles

    private enum BreakdownPopover {
        case models
        case sessionTime
        case tokens
    }

    private static let tileMinHeight: CGFloat = 116

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
                    return "\(providerLabel) · \(share(usage.turns)) of turns"
                } ?? "No agent turns yet",
                footnote: providerName.map { name in
                    "Top provider: \(name) (\(share(provider?.turns ?? 0)))"
                },
                isInteractive: !summary.isEmpty,
                help: "Show the model and provider breakdown."
            )
        } popover: {
            UsageBreakdownPopover(
                title: "Model usage",
                subtitle: "\(range.longTitle) · share of \(summary.turns) \(summary.turns == 1 ? "turn" : "turns")",
                charts: [
                    .init(title: "By model", unit: "turns", slices: modelSlices),
                    .init(title: "By provider", unit: "turns", slices: providerSlices),
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
                    ? "No agent turns yet"
                    : "\(summary.turns) \(summary.turns == 1 ? "turn" : "turns")",
                footnote: summary.isEmpty
                    ? nil
                    : "Avg \(Self.formatDuration(summary.sessionSeconds / Double(summary.turns))) per turn",
                isInteractive: !summary.isEmpty,
                help: "Show session time by provider and model."
            )
        } popover: {
            UsageBreakdownPopover(
                title: "Session time",
                subtitle: "\(range.longTitle) · \(Self.formatDuration(summary.sessionSeconds)) of agent work",
                charts: [
                    .init(title: "By provider", unit: "time", slices: providerTimeSlices, format: Self.formatDuration),
                    .init(title: "By model", unit: "time", slices: modelTimeSlices, format: Self.formatDuration),
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
                    ? "No agent turns yet"
                    : "\(Self.formatTokens(summary.inputTokens)) in · \(Self.formatTokens(summary.outputTokens)) out",
                footnote: summary.isEmpty
                    ? nil
                    : "\(Self.formatTokens(summary.cacheReadTokens + summary.cacheCreationTokens)) cache",
                isInteractive: !summary.isEmpty,
                help: "Show the token breakdown."
            )
        } popover: {
            UsageBreakdownPopover(
                title: "Token usage",
                subtitle: "\(range.longTitle) · \(summary.totalTokens.formatted()) tokens",
                charts: [
                    .init(title: "By type", unit: "tokens", slices: tokenTypeSlices),
                    .init(title: "By model", unit: "tokens", slices: modelTokenSlices),
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
        title: String,
        value: String,
        detail: String,
        footnote: String?,
        isInteractive: Bool,
        help: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClaudeTheme.textSecondary)
                Spacer(minLength: 0)
                if isInteractive {
                    Image(systemName: "chart.pie")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(ClaudeTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.numericText())
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .lineLimit(1)
            // Always reserve the footnote line so every tile has the same height.
            Text(footnote ?? " ")
                .font(.system(size: 10.5))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: Self.tileMinHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .fill(ClaudeTheme.surfacePrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous)
                .strokeBorder(ClaudeTheme.border.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusLarge, style: .continuous))
        .help(help)
        .animation(.easeInOut(duration: 0.2), value: value)
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
            (id: "input", label: "Input", detail: nil, value: Double(summary.inputTokens)),
            (id: "output", label: "Output", detail: nil, value: Double(summary.outputTokens)),
            (id: "cacheRead", label: "Cache read", detail: nil, value: Double(summary.cacheReadTokens)),
            (id: "cacheWrite", label: "Cache write", detail: nil, value: Double(summary.cacheCreationTokens)),
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
