import SwiftUI

/// Shared presentation for native desktop and mobile briefing surfaces.
public struct UsagePluginCard: View {
    public let snapshot: UsagePluginSnapshot
    public let configuration: UsageCardConfiguration
    public let showsDetailIndicator: Bool
    public let reservesEditControlSpace: Bool
    public init(snapshot: UsagePluginSnapshot, configuration: UsageCardConfiguration,
                showsDetailIndicator: Bool = false, reservesEditControlSpace: Bool = false) {
        self.snapshot = snapshot; self.configuration = configuration
        self.showsDetailIndicator = showsDetailIndicator
        self.reservesEditControlSpace = reservesEditControlSpace
    }
    private var metrics: [UsageMetric] {
        let matching = snapshot.metrics.filter { configuration.includesMetric($0.id) }
        return configuration.style == "metrics" ? matching : Array(matching.prefix(configuration.style == "compact" ? 1 : 3))
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: configuration.style == "compact" ? 6 : 14) {
            header
            switch configuration.style {
            case "compact": compactContent
            case "metrics": metricsContent
            default: summaryContent
            }
            if let error = snapshot.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if metrics.isEmpty && snapshot.error == nil {
                Text("No selected usage data for this period").font(.caption).foregroundStyle(.secondary)
            }
            Text("Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))\(snapshot.isStale() ? " · Stale" : "")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(configuration.style == "compact" ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
                Text(snapshot.title).font(.headline)
                if reservesEditControlSpace {
                    Spacer(minLength: 12)
                    Color.clear.frame(width: 24, height: 18).accessibilityHidden(true)
                } else if showsDetailIndicator {
                    Spacer(minLength: 12)
                    Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let metric = metrics.first {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(metric.title).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(metric.formattedValue).font(.title3.bold()).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("\(snapshot.scope) · \(snapshot.period)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(snapshot.scope) · \(snapshot.period)").font(.caption).foregroundStyle(.secondary)
            if let primary = metrics.first {
                VStack(alignment: .leading, spacing: 6) {
                    Text(primary.title).font(.subheadline).foregroundStyle(.secondary)
                    Text(primary.formattedValue).font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.7).lineLimit(2)
                    if let detail = primary.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
            if metrics.count > 1 {
                Divider()
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(metrics.dropFirst())) { metric in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title).font(.caption).foregroundStyle(.secondary)
                            Text(metric.formattedValue).font(.headline).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var metricsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(snapshot.scope) · \(snapshot.period)").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Metric")
                Spacer()
                Text("Value")
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider()
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(metric.title).font(.subheadline)
                        Spacer(minLength: 0)
                        Text(metric.formattedValue).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                    if let detail = metric.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
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
                    }
                }.padding(.vertical, 2)
                Divider()
            }
        }
    }
}
