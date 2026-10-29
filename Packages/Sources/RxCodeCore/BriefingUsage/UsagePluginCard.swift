import SwiftUI

/// Shared presentation for native desktop and mobile briefing surfaces.
/// The card fills the cell `UsageCardGridLayout` gives it, and its content
/// adapts to the configured widget-style size.
public struct UsagePluginCard: View {
    public let snapshot: UsagePluginSnapshot
    public let configuration: UsageCardConfiguration
    public let showsDetailIndicator: Bool
    public let reservesEditControlSpace: Bool
    /// Replaces the usage info with placeholder rails while a fetch runs.
    public let isRefreshing: Bool
    public init(snapshot: UsagePluginSnapshot, configuration: UsageCardConfiguration,
                showsDetailIndicator: Bool = false, reservesEditControlSpace: Bool = false,
                isRefreshing: Bool = false) {
        self.snapshot = snapshot; self.configuration = configuration
        self.showsDetailIndicator = showsDetailIndicator
        self.reservesEditControlSpace = reservesEditControlSpace
        self.isRefreshing = isRefreshing
    }

    private var size: UsageCardSize { configuration.cardSize }
    private var selectedMetrics: [UsageMetric] {
        let matching = snapshot.metrics.filter { configuration.includesMetric($0.id) }
        if snapshot.pluginID == "vercel", configuration.selectedMetricIDs.isEmpty,
           configuration.style == "summary" {
            return matching.filter { $0.id.hasPrefix("billable|") || $0.id == "ai-gateway-balance" }
        }
        return configuration.style == "compact" ? Array(matching.prefix(1)) : matching
    }
    private var metrics: [UsageMetric] { Array(selectedMetrics.prefix(size.metricCapacity)) }
    private var hiddenMetricCount: Int { selectedMetrics.count - metrics.count }
    private var usesTable: Bool { configuration.style == "metrics" }

    public var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 6 : 10) {
            header
            if isRefreshing {
                UsageCardRails(size: size)
                Spacer(minLength: 0)
                Text("Refreshing…").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                switch size {
                case .small: smallContent
                case .medium: mediumContent
                case .large, .xlarge: usesTable ? AnyView(tableContent) : AnyView(summaryContent)
                }
                Spacer(minLength: 0)
                footer
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isRefreshing)
        .padding(size == .small ? 12 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(snapshot.title).font(size == .small ? .subheadline.weight(.semibold) : .headline).lineLimit(1)
            if reservesEditControlSpace {
                Spacer(minLength: 8)
                Color.clear.frame(width: 24, height: 18).accessibilityHidden(true)
            } else if showsDetailIndicator {
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var scopeLine: some View {
        Text("\(snapshot.scope) · \(snapshot.period)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
    }

    @ViewBuilder private var footer: some View {
        if let error = snapshot.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                .lineLimit(size == .small ? 1 : 2)
        } else if metrics.isEmpty {
            Text("No selected usage data for this period").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        HStack(spacing: 6) {
            if hiddenMetricCount > 0 {
                Text("+\(hiddenMetricCount) more").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(size == .small
                 ? "\(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))\(snapshot.isStale() ? " · Stale" : "")"
                 : "Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))\(snapshot.isStale() ? " · Stale" : "")")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func hero(_ metric: UsageMetric, valueSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(metric.formattedValue).font(.system(size: valueSize, weight: .semibold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            if let detail = metric.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private func supporting(_ metric: UsageMetric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(metric.formattedValue).font(.subheadline.weight(.semibold)).monospacedDigit()
                .minimumScaleFactor(0.7).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var smallContent: some View {
        scopeLine
        if let metric = metrics.first { hero(metric, valueSize: 24) }
    }

    @ViewBuilder private var mediumContent: some View {
        scopeLine
        HStack(alignment: .top, spacing: 14) {
            if let primary = metrics.first {
                hero(primary, valueSize: 28).frame(maxWidth: .infinity, alignment: .leading)
            }
            if metrics.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(metrics.dropFirst())) { supporting($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            scopeLine
            if let primary = metrics.first { hero(primary, valueSize: size == .xlarge ? 38 : 32) }
            if metrics.count > 1 {
                Divider()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .topLeading),
                                         count: size == .xlarge ? 4 : 2),
                          alignment: .leading, spacing: 12) {
                    ForEach(Array(metrics.dropFirst())) { supporting($0) }
                }
            }
        }
    }

    private var tableContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            scopeLine
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top),
                                     count: size == .xlarge ? 2 : 1),
                      alignment: .leading, spacing: 8) {
                ForEach(metrics) { metricRow($0) }
            }
        }
    }

    private func metricRow(_ metric: UsageMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(metric.title).font(.subheadline).lineLimit(1)
                Spacer(minLength: 0)
                Text(metric.formattedValue).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1)
            }
            if metric.unit == "%", let value = metric.value, value.isFinite {
                GeometryReader { proxy in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.accentColor)
                                .frame(width: proxy.size.width * min(max(value, 0), 100) / 100)
                        }
                }
                .frame(height: 5)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metric.title)
                .accessibilityValue(metric.formattedValue)
            } else if let detail = metric.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
        }
    }
}

/// Pulsing placeholder rails shown in place of usage info during a refresh.
private struct UsageCardRails: View {
    let size: UsageCardSize
    @State private var dimmed = false

    private var widths: [CGFloat] {
        switch size {
        case .small: [0.5, 0.8]
        case .medium: [0.4, 0.7, 0.55]
        case .large: [0.4, 0.75, 0.9, 0.6, 0.85, 0.5]
        case .xlarge: [0.3, 0.6, 0.8, 0.7, 0.9, 0.5]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, fraction in
                GeometryReader { proxy in
                    Capsule().fill(.quaternary)
                        .frame(width: proxy.size.width * fraction)
                }
                .frame(height: index == 1 ? 22 : 10)
            }
        }
        .opacity(dimmed ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
        .onAppear { dimmed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Refreshing usage")
    }
}
