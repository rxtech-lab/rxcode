import Charts
import SwiftUI
import RxCodeCore

/// Shared title block for the usage-limit detail popovers. Content scrolls
/// once it outgrows the popover's height cap.
struct RateLimitPopoverScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CappedScrollView(maxHeight: 560) {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
            }
        }
        .padding(18)
        .frame(width: 680, alignment: .leading)
    }
}

/// Scrolls its content once it grows past `maxHeight`; shorter content keeps
/// its natural height so the popover doesn't show empty space.
private struct CappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.automatic)
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

/// "How to read this" block: each term shown in the table next to what it
/// means.
struct RateLimitGlossary: View {
    struct Entry: Identifiable {
        let term: LocalizedStringKey
        let detail: LocalizedStringKey
        let id = UUID()
    }

    let entries: [Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to read this")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(entries) { entry in
                    GridRow {
                        Text(entry.term)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ClaudeTheme.textSecondary)
                            .gridColumnAlignment(.trailing)
                        Text(entry.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusMedium, style: .continuous)
                .fill(ClaudeTheme.surfaceSecondary.opacity(0.6))
        )
    }
}

/// One provider's block in a popover table: colored header, then rows
/// separated by dividers.
struct ProviderTableSection<Row: Identifiable, RowContent: View>: View {
    let provider: AgentProvider
    let rows: [Row]
    @ViewBuilder let row: (Row) -> RowContent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(provider)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ClaudeTheme.textSecondary)
                .padding(.bottom, 6)
            ClaudeThemeDivider()
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                if index > 0 { ClaudeThemeDivider() }
                row(item)
                    .padding(.vertical, 6)
            }
        }
    }
}

func emptyMessage(_ text: LocalizedStringKey) -> some View {
    Text(text)
        .font(.system(size: 12))
        .foregroundStyle(ClaudeTheme.textTertiary)
        .frame(maxWidth: .infinity, minHeight: 120)
}

func providerColor(_ provider: AgentProvider) -> Color {
    UsageBreakdownPopover.Slice.palette[provider == .codex ? 1 : 0]
}

/// False for plans without a separate 5-hour limit.
@MainActor
func hasFiveHourLimit(_ provider: AgentProvider, in appState: AppState) -> Bool {
    appState.cachedRateLimitUsage(for: provider)?.hasFiveHourLimit ?? true
}

private func sectionHeader(_ provider: AgentProvider) -> some View {
    HStack(spacing: 6) {
        Circle().fill(providerColor(provider)).frame(width: 7, height: 7)
        Text(provider.displayNameText)
    }
}

// MARK: - History

/// Popover with the 5-hour and 7-day usage-limit history of every provider as
/// a line chart.
struct RateLimitHistoryPopover: View {
    @Environment(AppState.self) private var appState

    let providers: [AgentProvider]
    let range: UsageStatsRange

    @State private var samples: [AgentProvider: [RateLimitSamplePoint]] = [:]
    @State private var selectedDate: Date?
    /// Comma-separated raw values of the series switched off in the filter.
    @AppStorage("rateLimitHistoryHiddenProviders") private var hiddenProvidersRaw = ""
    @AppStorage("rateLimitHistoryHiddenWindows") private var hiddenWindowsRaw = ""
    @State private var showsFilter = false

    /// Points plotted per provider; longer histories are thinned evenly.
    private static let maxPointsPerProvider = 400

    private enum LimitWindow: String, CaseIterable {
        case fiveHour
        case sevenDay

        var title: LocalizedStringKey {
            switch self {
            case .fiveHour: "5-hour limit"
            case .sevenDay: "7-day limit"
            }
        }
    }

    private struct Point: Identifiable {
        let provider: AgentProvider
        let window: LimitWindow
        let date: Date
        let percent: Double
        var id: String { "\(provider.rawValue)|\(window.rawValue)|\(date.timeIntervalSince1970)" }
    }

    private var hiddenProviders: Set<String> {
        Set(hiddenProvidersRaw.split(separator: ",").map(String.init))
    }

    private var hiddenWindows: Set<String> {
        Set(hiddenWindowsRaw.split(separator: ",").map(String.init))
    }

    private var visibleProviders: [AgentProvider] {
        providers.filter { !hiddenProviders.contains($0.rawValue) }
    }

    private var visibleWindows: [LimitWindow] {
        LimitWindow.allCases.filter { !hiddenWindows.contains($0.rawValue) }
    }

    /// Visible windows the provider's plan actually has.
    private func windows(for provider: AgentProvider) -> [LimitWindow] {
        hasFiveHourLimit(provider, in: appState) ? visibleWindows : visibleWindows.filter { $0 != .fiveHour }
    }

    private var points: [Point] {
        visibleProviders.flatMap { provider in
            (samples[provider] ?? []).flatMap { sample in
                windows(for: provider).map { window in
                    Point(
                        provider: provider,
                        window: window,
                        date: sample.capturedAt,
                        percent: window == .fiveHour ? sample.fiveHourPercent : sample.sevenDayPercent
                    )
                }
            }
        }
    }

    private var isFiltered: Bool {
        !hiddenProviders.isEmpty || !hiddenWindows.isEmpty
    }

    private var isEmpty: Bool {
        samples.values.allSatisfy(\.isEmpty)
    }

    var body: some View {
        RateLimitPopoverScaffold(
            title: String(localized: "Usage-limit history"),
            subtitle: String(localized: "\(range.localizedLongTitle) · share of each limit used. Solid lines are 5-hour limits, dashed lines 7-day limits.")
        ) {
            if isEmpty {
                emptyMessage("No usage-limit history in this window yet.")
            } else {
                chart
                legend
            }
        }
        .task(id: appState.rateLimitHistoryRevision) {
            var result: [AgentProvider: [RateLimitSamplePoint]] = [:]
            for provider in providers {
                result[provider] = Self.thinned(appState.rateLimitSamples(for: provider, range: range))
            }
            samples = result
        }
    }

    private static func thinned(_ points: [RateLimitSamplePoint]) -> [RateLimitSamplePoint] {
        guard points.count > maxPointsPerProvider else { return points }
        let step = Double(points.count - 1) / Double(maxPointsPerProvider - 1)
        return (0..<maxPointsPerProvider).map { points[Int((Double($0) * step).rounded())] }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Used", point.percent),
                    series: .value("Series", "\(point.provider.rawValue) \(point.window.rawValue)")
                )
                .foregroundStyle(by: .value("Provider", point.provider.displayNameText))
                .lineStyle(point.window == .fiveHour
                    ? StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    : StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
            }

            if let selectedDate {
                RuleMark(x: .value("Time", selectedDate))
                    .foregroundStyle(ClaudeTheme.border)
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(at: selectedDate)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: providers.map(\.displayNameText),
            range: providers.map(providerColor)
        )
        .chartLegend(.hidden)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%")
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .frame(height: 260)
        // Room for the top "100%" axis label, which the scroll view would clip.
        .padding(.top, 8)
    }

    /// Each provider's reading closest to the pointer.
    private func readout(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10.5))
                .foregroundStyle(ClaudeTheme.textTertiary)
            ForEach(visibleProviders, id: \.self) { provider in
                if let sample = (samples[provider] ?? []).min(by: {
                    abs($0.capturedAt.timeIntervalSince(date)) < abs($1.capturedAt.timeIntervalSince(date))
                }) {
                    Text(verbatim: "\(provider.displayNameText) \(readoutValues(sample, provider: provider))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                }
            }
        }
        .foregroundStyle(ClaudeTheme.textPrimary)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall, style: .continuous)
                .fill(ClaudeTheme.surfaceSecondary)
        )
    }

    /// The visible windows' readings, e.g. `36% · 19%`.
    private func readoutValues(_ sample: RateLimitSamplePoint, provider: AgentProvider) -> String {
        windows(for: provider).map { window in
            BriefingRateLimitStatsView.formatPercent(window == .fiveHour ? sample.fiveHourPercent : sample.sevenDayPercent)
        }
        .joined(separator: " · ")
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(visibleProviders, id: \.self) { provider in
                HStack(spacing: 6) {
                    Capsule().fill(providerColor(provider)).frame(width: 14, height: 3)
                    Text(provider.displayNameText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                    if let latest = samples[provider]?.last, !windows(for: provider).isEmpty {
                        Text("now \(readoutValues(latest, provider: provider))")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
            }
            Spacer()
            Text("Solid 5-hour · dashed 7-day")
                .font(.system(size: 11))
                .foregroundStyle(ClaudeTheme.textTertiary)
            filterButton
        }
    }

    private var filterButton: some View {
        Button {
            showsFilter.toggle()
        } label: {
            Image(systemName: isFiltered
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.borderless)
        .help("Choose which providers and limits to show.")
        .popover(isPresented: $showsFilter, arrowEdge: .bottom) {
            filterPopover
        }
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterSectionTitle("Providers")
            ForEach(providers, id: \.self) { provider in
                Toggle(isOn: visibility(of: provider.rawValue, in: $hiddenProvidersRaw)) {
                    HStack(spacing: 6) {
                        Circle().fill(providerColor(provider)).frame(width: 7, height: 7)
                        Text(provider.displayNameText)
                    }
                }
            }
            ClaudeThemeDivider()
            filterSectionTitle("Usage limits")
            ForEach(LimitWindow.allCases, id: \.self) { window in
                Toggle(window.title, isOn: visibility(of: window.rawValue, in: $hiddenWindowsRaw))
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .padding(14)
        .frame(minWidth: 200, alignment: .leading)
    }

    private func filterSectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(ClaudeTheme.textTertiary)
            .textCase(.uppercase)
    }

    /// Checkbox binding that is on while `item` isn't in the persisted,
    /// comma-separated hidden list.
    private func visibility(of item: String, in hiddenRaw: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { !hiddenRaw.wrappedValue.split(separator: ",").contains(Substring(item)) },
            set: { isVisible in
                var hidden = Set(hiddenRaw.wrappedValue.split(separator: ",").map(String.init))
                if isVisible {
                    hidden.remove(item)
                } else {
                    hidden.insert(item)
                }
                hiddenRaw.wrappedValue = hidden.sorted().joined(separator: ",")
            }
        )
    }
}
