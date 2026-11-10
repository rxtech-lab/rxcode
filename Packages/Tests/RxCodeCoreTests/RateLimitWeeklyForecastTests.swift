import Foundation
import Testing
@testable import RxCodeCore

@Suite("Daily activity depletion forecast")
struct RateLimitWeeklyForecastTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_800_014_400)

    private func bucket(daysAgo: Int, tokens: Int = 100_000, seconds: Double = 600,
                        model: String = "opus", provider: String = "claudeCode") -> UsageStatBucketSnapshot {
        .init(bucketStart: calendar.startOfDay(for: now).addingTimeInterval(-Double(daysAgo) * 86_400),
              projectId: nil, providerRaw: provider, model: model, sessionSeconds: seconds,
              turns: 3, inputTokens: tokens, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 9_000_000)
    }

    private func costs(tokens: Int = 100_000, concurrent: Int = 0, delta: Double? = 10,
                       model: String = "opus") -> [RateLimitTaskCostSnapshot] {
        (1...3).map { index in
            let end = now.addingTimeInterval(-Double(index) * 86_400 + 600)
            return .init(providerRaw: "claudeCode", model: model, startedAt: end.addingTimeInterval(-600),
                         endedAt: end, fiveHourDelta: nil, sevenDayDelta: delta,
                         concurrentRuns: concurrent, tokens: tokens)
        }
    }

    private func forecast(used: Double = 80, costs: [RateLimitTaskCostSnapshot]? = nil,
                          buckets: [UsageStatBucketSnapshot]? = nil, resetDays: Double = 4) -> RateLimitWeeklyForecast {
        .estimate(providerRaw: "claudeCode",
                  usage: .init(fiveHourPercent: 0, sevenDayPercent: used,
                               fiveHourResetsAt: nil,
                               sevenDayResetsAt: now.addingTimeInterval(resetDays * 86_400)),
                  costs: costs ?? self.costs(),
                  dailyBuckets: buckets ?? [bucket(daysAgo: 1), bucket(daysAgo: 2)], now: now, calendar: calendar)
    }

    @Test func forecastsDateFromDailyUncachedTokens() {
        let result = forecast()
        #expect(result.dailyTokens == 100_000)
        #expect(result.dailySessionSeconds == 600)
        #expect(result.dailyPercent == 10)
        #expect(result.outcome == .depletes(now.addingTimeInterval(2 * 86_400)))
    }

    @Test func includesIdleDaysAndIgnoresPartialTodayAndOtherProviders() {
        let result = forecast(buckets: [bucket(daysAgo: 1), bucket(daysAgo: 4),
                                       bucket(daysAgo: 0, tokens: 99_000_000),
                                       bucket(daysAgo: 2, tokens: 99_000_000, provider: "codex")])
        #expect(result.observedDays == 4)
        #expect(result.dailyPercent == 5)
        #expect(result.outcome == .lastsUntilReset)
    }

    @Test func fallsBackToSessionDurationWhenTokensUnavailable() {
        let result = forecast(costs: costs(tokens: 0), buckets: [bucket(daysAgo: 1, tokens: 0), bucket(daysAgo: 2, tokens: 0)])
        #expect(result.dailyPercent == 10)
        #expect(result.outcome == .depletes(now.addingTimeInterval(2 * 86_400)))
    }

    @Test func rejectsSparseConcurrentZeroAndInvalidMeasurements() {
        #expect(forecast(buckets: [bucket(daysAgo: 1)]).outcome == .insufficientData)
        #expect(forecast(costs: Array(costs().prefix(2))).outcome == .insufficientData)
        #expect(forecast(costs: costs(concurrent: 1)).outcome == .insufficientData)
        #expect(forecast(costs: costs(delta: 0)).outcome == .insufficientData)
        #expect(forecast(costs: costs(delta: .nan)).outcome == .insufficientData)
        #expect(forecast(costs: costs(delta: nil)).outcome == .insufficientData)
        #expect(forecast(used: .nan).outcome == .insufficientData)
        #expect(forecast(resetDays: -1).outcome == .insufficientData)
        #expect(forecast(used: 100).outcome == .exhausted)
    }

    @Test func appliesModelSpecificCostsAndRequiresCoverage() {
        let buckets = [bucket(daysAgo: 1), bucket(daysAgo: 2),
                       bucket(daysAgo: 1, model: "sonnet"), bucket(daysAgo: 2, model: "sonnet")]
        #expect(forecast(buckets: buckets).outcome == .insufficientData)
        let result = forecast(costs: costs() + costs(delta: 2, model: "sonnet"), buckets: buckets)
        #expect(abs(result.dailyPercent - 12) < 0.0001)
    }

    @Test func dailyForecastOverridesElapsedWindowWarning() {
        let usage = RateLimitUsage(fiveHourPercent: 0, sevenDayPercent: 60,
                                  fiveHourResetsAt: nil,
                                  sevenDayResetsAt: now.addingTimeInterval(5 * 86_400))
        var summary = RateLimitTaskCostSummary()
        summary.weeklyForecast.outcome = .lastsUntilReset
        let context = RateLimitAdvisor.ProviderContext(providerRaw: "claudeCode", displayName: "Claude Code", usage: usage, summary: summary)
        #expect(RateLimitAdvisor.advise(context: context, model: nil, now: now) == nil)
        summary.weeklyForecast = forecast()
        let warningContext = RateLimitAdvisor.ProviderContext(providerRaw: "claudeCode", displayName: "Claude Code", usage: usage, summary: summary)
        #expect(RateLimitAdvisor.advise(context: warningContext, model: nil, now: now)?.reasons.contains { $0.contains("daily sessions and tokens") } == true)
    }
}
