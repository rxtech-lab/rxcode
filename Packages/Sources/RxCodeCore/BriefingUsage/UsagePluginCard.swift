import SwiftUI

/// Shared presentation for native desktop and mobile briefing surfaces.
public struct UsagePluginCard: View {
    public let snapshot: UsagePluginSnapshot
    public let configuration: UsageCardConfiguration
    public init(snapshot: UsagePluginSnapshot, configuration: UsageCardConfiguration) {
        self.snapshot = snapshot; self.configuration = configuration
    }
    private var metrics: [UsageMetric] {
        let matching = snapshot.metrics.filter { configuration.metricID == nil || $0.id == configuration.metricID }
        return configuration.style == "metrics" ? matching : Array(matching.prefix(configuration.style == "compact" ? 1 : 3))
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snapshot.title).font(.headline)
            Text("\(snapshot.scope) · \(snapshot.period)").font(.caption).foregroundStyle(.secondary)
            ForEach(metrics) { metric in
                HStack {
                    VStack(alignment: .leading) {
                        Text(metric.title).font(.caption)
                        if let detail = metric.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(metric.formattedValue).font(.headline).monospacedDigit()
                }
            }
            if let error = snapshot.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            if snapshot.metrics.isEmpty && snapshot.error == nil { Text("No usage data for this period").foregroundStyle(.secondary) }
            Text("Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))\(snapshot.isStale() ? " · Stale" : "")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}
