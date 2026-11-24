import Foundation
import RxCodeCore
import RxCodeExtensionSDK
import Testing
@testable import AILimits

struct AILimitsTests {
    @Test func preservesWindowsTaskEstimatesAndOldestReading() async throws {
        let integration = UsageIntegration(pluginID: "ai-limits", title: "Account limits")
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(integration))
        let older = Date(timeIntervalSince1970: 400)
        let newer = older.addingTimeInterval(60)
        let usage = RateLimitUsage(fiveHourPercent: 19, sevenDayPercent: 19, fiveHourResetsAt: newer, sevenDayResetsAt: newer)
        var costs = RateLimitTaskCostSummary()
        costs.averageFiveHour = 2.5
        costs.remainingFiveHour = .tasks(29)
        costs.sampleCount = 4
        let reports = [
            RateLimitReportDTO(provider: .claudeCode, range: .week, current: nil, history: [], costs: .init(), measuredAt: newer),
            RateLimitReportDTO(provider: .codex, range: .week, current: usage, history: [], costs: costs, measuredAt: older)
        ]
        let host = RxCodeHost { request in
            #expect(request.operation == .rateLimits)
            #expect(try request.decode([String: String].self) == ["range": "week"])
            return try ExtensionResponse(replyingTo: request, value: reports)
        }
        let snapshot = try await AILimitsProvider.fetch(input, host: host)
        #expect(snapshot.fetchedAt == older)
        #expect(snapshot.period == "Current limits · 7-day task samples")
        #expect(snapshot.metrics.map(\.id) == ["claudeCode:5h", "claudeCode:7d", "claudeCode:cost", "codex:5h", "codex:7d", "codex:cost", "codex:remaining"])
        #expect(snapshot.metrics.map(\.value) == [nil, nil, nil, nil, 19, 2.5, 29])
        #expect(snapshot.metrics[5].detail == "4 samples · 5h window")
    }

    @Test func noReadingsKeepUnknownSuccessTime() async throws {
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(UsageIntegration(pluginID: "ai-limits", title: "Quota")))
        let host = RxCodeHost { try ExtensionResponse(replyingTo: $0, value: [RateLimitReportDTO]()) }
        let snapshot = try await AILimitsProvider.fetch(input, host: host)
        #expect(snapshot.fetchedAt == .distantPast)
    }
}
