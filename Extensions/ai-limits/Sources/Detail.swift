import Charts
import SwiftUI

struct LimitDetail: View {
    enum Section: String, CaseIterable {
        case history = "History", costs = "Task costs", models = "Model estimates", forecast = "Forecast"
    }
    let reports: [LimitReport]
    let metric: String?
    @State private var section = Section.history

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Details", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            if hasData {
                List(reports) { report in
                    SwiftUI.Section(report.providerLabel) {
                        switch section {
                        case .history:
                            if !report.history.isEmpty {
                                Chart(report.history, id: \.capturedAt) { sample in
                                    if report.hasFiveHourLimit {
                                        LineMark(x: .value(String(localized: "Date"), sample.capturedAt), y: .value(String(localized: "Usage (%)"), sample.fiveHourPercent))
                                            .foregroundStyle(by: .value(String(localized: "Window"), "5h"))
                                    }
                                    LineMark(x: .value(String(localized: "Date"), sample.capturedAt), y: .value(String(localized: "Usage (%)"), sample.sevenDayPercent))
                                        .foregroundStyle(by: .value(String(localized: "Window"), "7d"))
                                }
                                .chartYScale(domain: 0...100)
                                .frame(minHeight: 130)
                            }
                        case .costs:
                            ForEach(report.costs.tasks) { task in
                                LabeledContent(task.threadTitle, value: windowCosts(task))
                            }
                        case .models:
                            ForEach(report.costs.models) { model in
                                LabeledContent(model.model.isEmpty ? String(localized: "Default") : model.model,
                                               value: "5h · \(estimate(model.remainingFiveHour))   7d · \(estimate(model.remainingSevenDay))")
                            }
                        case .forecast:
                            let forecast = report.costs.weeklyForecast
                            LabeledContent("Weekly limit", value: outcome(forecast))
                            if forecast.observedDays > 0 {
                                LabeledContent("Daily usage", value: "\(percent(forecast.dailyPercent)) · \(forecast.observedDays) days")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No measurements yet", systemImage: "chart.xyaxis.line")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .onChange(of: metric, initial: true) { _, id in
            if id?.hasSuffix(":cost") == true { section = .costs }
            else if id?.hasSuffix(":remaining") == true { section = .models }
            else { section = .history }
        }
    }

    private var hasData: Bool {
        reports.contains { report in
            switch section {
            case .history: !report.history.isEmpty
            case .costs: !report.costs.tasks.isEmpty
            case .models: !report.costs.models.isEmpty
            case .forecast: true
            }
        }
    }

    private func estimate(_ estimate: LimitReport.Estimate) -> String {
        switch estimate {
        case .insufficientData: String(localized: "Insufficient data")
        case .unbounded: String(localized: "No measured cost")
        case .tasks(let count): String(localized: "\(count) tasks")
        }
    }

    private func outcome(_ forecast: LimitReport.Forecast) -> String {
        switch forecast.outcome {
        case .insufficientData: String(localized: "Insufficient data")
        case .exhausted: String(localized: "Exhausted")
        case .lastsUntilReset: String(localized: "Lasts until reset")
        case .depletes(let date): String(localized: "Depletes \(date.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    private func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }

    private func windowCosts(_ task: LimitReport.TaskCost) -> String {
        ["5h · " + (task.fiveHourDelta.map(percent) ?? String(localized: "Unavailable")),
         "7d · " + (task.sevenDayDelta.map(percent) ?? String(localized: "Unavailable"))].joined(separator: "   ")
    }
}
