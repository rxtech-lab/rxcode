import Foundation
import RxCodeExtensionSDK

struct LimitReport: Decodable, Sendable, Identifiable {
    struct Reading: Decodable, Sendable {
        let fiveHourPercent, sevenDayPercent: Double
    }
    struct Point: Decodable, Sendable {
        let capturedAt: Date
        let fiveHourPercent, sevenDayPercent: Double
    }
    enum Estimate: Decodable, Sendable {
        case insufficientData, unbounded, tasks(Int)
    }
    struct TaskCost: Decodable, Sendable, Identifiable {
        let id: UUID
        let threadTitle: String
        let endedAt: Date
        let fiveHourDelta, sevenDayDelta: Double?
    }
    struct Model: Decodable, Sendable, Identifiable {
        let model: String
        let remainingFiveHour, remainingSevenDay: Estimate
        var id: String { model }
    }
    struct Forecast: Decodable, Sendable {
        enum Outcome: Decodable, Sendable {
            case insufficientData, exhausted, lastsUntilReset, depletes(Date)
        }
        let outcome: Outcome
        let observedDays: Int
        let dailyPercent: Double
    }
    struct Costs: Decodable, Sendable {
        let sampleCount: Int
        let averageFiveHour: Double?
        let remainingFiveHour: Estimate
        let tasks: [TaskCost]
        let models: [Model]
        let weeklyForecast: Forecast
    }
    let provider, providerLabel: String
    let measuredAt: Date?
    let hasFiveHourLimit: Bool
    let current: Reading?
    let history: [Point]
    let costs: Costs
    var id: String { provider }
}

enum AILimitsProvider {
    static func reports(_ host: RxCodeHost) async throws -> [LimitReport] {
        try await host.call(.rateLimits, ["range": "week"], returning: [LimitReport].self)
    }

    static func fetch(_ integration: ExtensionUsageIntegration, host: RxCodeHost) async throws -> ExtensionUsageSnapshot {
        guard integration.pluginID == "ai-limits" else { throw ExtensionCallError.invalidRequest }
        let reports = try await reports(host)
        var metrics: [ExtensionUsageSnapshot.Metric] = []
        for report in reports {
            let prefix = report.provider + ":"
            let title = report.providerLabel + " · "
            let costs = report.costs
            metrics.append(.init(id: prefix + "5h", title: title + "5h",
                                 value: report.hasFiveHourLimit ? report.current?.fiveHourPercent : nil, unit: "%"))
            metrics.append(.init(id: prefix + "7d", title: title + "7d", value: report.current?.sevenDayPercent, unit: "%"))
            metrics.append(.init(id: prefix + "cost", title: title + "Average task cost", value: costs.averageFiveHour,
                                 unit: "%", detail: "\(costs.sampleCount) samples · 5h window"))
            if case .tasks(let count) = costs.remainingFiveHour {
                metrics.append(.init(id: prefix + "remaining", title: title + "Estimated remaining", value: Double(count), unit: "tasks"))
            }
        }
        return ExtensionUsageSnapshot(integration: integration, scope: integration.projectID == nil ? "All projects" : "Project",
                                      period: "Current limits · 7-day task samples", fetchedAt: reports.compactMap(\.measuredAt).min() ?? .distantPast,
                                      metrics: metrics)
    }
}
