import Charts
import SwiftUI

struct UsageDetail: View {
    let report: UsageReport
    let metric: String?
    @State private var byModel = true

    private var unit: String {
        switch metric {
        case "tokens": String(localized: "Tokens")
        case "time": String(localized: "Seconds")
        default: String(localized: "Agent turns")
        }
    }

    var body: some View {
        if report.summary.turns == 0 {
            ContentUnavailableView("No AI usage yet", systemImage: "chart.pie",
                                   description: Text("Model and provider breakdowns appear after agent activity."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading) {
                Picker("Breakdown", selection: $byModel) {
                    Text("By model").tag(true)
                    Text("By provider").tag(false)
                }.pickerStyle(.segmented)
                let items = byModel ? report.summary.models : report.summary.providers
                Chart(items) { row in
                    SectorMark(angle: .value(unit, row.value(for: metric)), innerRadius: .ratio(0.58))
                        .foregroundStyle(by: .value(String(localized: "Group"), row.id))
                        .accessibilityLabel(label(row))
                }
                .chartLegend(.hidden)
                .frame(minHeight: 120)
                List(items) { row in
                    LabeledContent(label(row), value: "\(row.value(for: metric).formatted()) \(unit.lowercased())")
                }
            }
            .padding()
        }
    }

    private func label(_ row: UsageReport.Breakdown) -> String {
        if byModel { return report.label(for: row) }
        return report.providerLabels[row.providerRaw] ?? row.providerRaw
    }
}
