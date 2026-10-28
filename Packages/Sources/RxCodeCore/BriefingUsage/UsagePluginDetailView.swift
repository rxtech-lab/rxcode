import SwiftUI

/// Default plugin detail presentation. Native plugins can provide their own
/// charts or navigation by implementing `UsagePlugin.detailView`.
public struct UsagePluginDetailView: View {
    public let snapshot: UsagePluginSnapshot
    public let configuration: UsageCardConfiguration

    public init(snapshot: UsagePluginSnapshot, configuration: UsageCardConfiguration) {
        self.snapshot = snapshot
        self.configuration = configuration
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title).font(.title3.bold())
                Text(snapshot.scope).foregroundStyle(.secondary)
                Text(snapshot.period).font(.caption).foregroundStyle(.secondary)
            }
            if let error = snapshot.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if snapshot.metrics.isEmpty {
                ContentUnavailableView("No usage data", systemImage: "chart.bar",
                    description: Text("Refresh this integration to collect its metrics."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(snapshot.metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(metric.title).fontWeight(configuration.selectedMetricIDs.contains(metric.id) ? .semibold : .regular)
                            Spacer(minLength: 20)
                            Text(metric.formattedValue).monospacedDigit().fontWeight(.semibold)
                        }
                        if let detail = metric.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
            }
            Text("Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))\(snapshot.isStale() ? " · Stale" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
