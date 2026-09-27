import Foundation
import Testing
@testable import RxCodeCore

@Suite("Usage-limit history")
struct RateLimitHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usage(
        _ fiveHour: Double,
        _ sevenDay: Double,
        fiveHourResetsAt: Date? = nil,
        sevenDayResetsAt: Date? = nil
    ) -> RateLimitUsage {
        RateLimitUsage(
            fiveHourPercent: fiveHour,
            sevenDayPercent: sevenDay,
            fiveHourResetsAt: fiveHourResetsAt,
            sevenDayResetsAt: sevenDayResetsAt
        )
    }

    private func cost(
        model: String = "claude-opus-5-5",
        fiveHour: Double?,
        sevenDay: Double? = nil,
        tokens: Int = 0,
        concurrent: Int = 0,
        minutesAgo: Double = 0
    ) -> RateLimitTaskCostSnapshot {
        let end = now.addingTimeInterval(-minutesAgo * 60)
        return RateLimitTaskCostSnapshot(
            providerRaw: "claudeCode",
            model: model,
            startedAt: end.addingTimeInterval(-60),
            endedAt: end,
            fiveHourDelta: fiveHour,
            sevenDayDelta: sevenDay,
            concurrentRuns: concurrent,
            tokens: tokens
        )
    }

    // MARK: - Sampling

    @Test func recordsFirstChangedAndStaleSamples() {
        let previous = RateLimitSamplePoint(providerRaw: "claudeCode", capturedAt: now, fiveHourPercent: 10, sevenDayPercent: 5)
        #expect(RateLimitSample.shouldRecord(previous: nil, usage: usage(10, 5), at: now))
        #expect(!RateLimitSample.shouldRecord(previous: previous, usage: usage(10, 5), at: now.addingTimeInterval(60)))
        #expect(RateLimitSample.shouldRecord(previous: previous, usage: usage(11, 5), at: now.addingTimeInterval(60)))
        #expect(RateLimitSample.shouldRecord(previous: previous, usage: usage(10, 5), at: now.addingTimeInterval(11 * 60)))
    }

    // MARK: - Deltas

    @Test func deltaIsDifferenceWithinSameWindow() {
        let reset = now.addingTimeInterval(3600)
        let delta = RateLimitDelta.between(
            usage(10, 4, fiveHourResetsAt: reset, sevenDayResetsAt: reset),
            usage(13.5, 5, fiveHourResetsAt: reset, sevenDayResetsAt: reset)
        )
        #expect(delta.fiveHour == 3.5)
        #expect(delta.sevenDay == 1)
    }

    @Test func deltaIsNilWhenWindowResets() {
        let delta = RateLimitDelta.between(
            usage(80, 40, fiveHourResetsAt: now, sevenDayResetsAt: now.addingTimeInterval(86_400)),
            usage(2, 41, fiveHourResetsAt: now.addingTimeInterval(5 * 3600), sevenDayResetsAt: now.addingTimeInterval(86_400))
        )
        #expect(delta.fiveHour == nil)
        #expect(delta.sevenDay == 1)
    }

    // MARK: - Summary

    @Test func summaryRanksMostAndLeastAndEstimatesRemaining() {
        let summary = RateLimitTaskCostSummary.aggregate(
            [cost(fiveHour: 2, sevenDay: 0.5), cost(fiveHour: 6, sevenDay: 1), cost(fiveHour: 4, sevenDay: 0.3)],
            current: usage(40, 70)
        )
        #expect(summary.sampleCount == 3)
        #expect(summary.averageFiveHour == 4)
        #expect(summary.mostExpensive?.fiveHourDelta == 6)
        #expect(summary.leastExpensive?.fiveHourDelta == 2)
        #expect(summary.remainingFiveHour == .tasks(15))
        #expect(summary.remainingSevenDay == .tasks(50))
    }

    @Test func summaryPrefersIsolatedTasksOnceEnoughExist() {
        let summary = RateLimitTaskCostSummary.aggregate(
            [cost(fiveHour: 1), cost(fiveHour: 1), cost(fiveHour: 1), cost(fiveHour: 10, concurrent: 2)],
            current: nil
        )
        #expect(summary.usesIsolatedSamplesOnly)
        #expect(summary.averageFiveHour == 1)
        #expect(summary.tasks.count == 4)
    }

    @Test func estimateHandlesMissingAndZeroCost() {
        #expect(RateLimitTaskCostSummary.estimate(used: 50, average: nil) == .insufficientData)
        #expect(RateLimitTaskCostSummary.estimate(used: 50, average: 0) == .unbounded)
        #expect(RateLimitTaskCostSummary.estimate(used: 120, average: 5) == .tasks(0))
    }

    @Test func perModelStatsAndAliasLookup() {
        let summary = RateLimitTaskCostSummary.aggregate(
            [
                cost(model: "claude-opus-5-5", fiveHour: 4, tokens: 100_000),
                cost(model: "claude-opus-5-5", fiveHour: 6, tokens: 100_000),
                cost(model: "claude-sonnet-5", fiveHour: 1, tokens: 100_000),
            ],
            current: usage(50, 10)
        )
        let opus = summary.stats(forModel: "opus")
        #expect(opus?.model == "claude-opus-5-5")
        #expect(opus?.averageFiveHour == 5)
        #expect(opus?.remainingFiveHour == .tasks(10))
        #expect(opus?.fiveHourPerMillionTokens == 50)
        #expect(summary.stats(forModel: "claude-sonnet-5")?.remainingFiveHour == .tasks(50))
    }

    // MARK: - Advice

    private func context(_ summary: RateLimitTaskCostSummary, usage: RateLimitUsage?, provider: String = "claudeCode") -> RateLimitAdvisor.ProviderContext {
        RateLimitAdvisor.ProviderContext(providerRaw: provider, displayName: provider, usage: usage, summary: summary)
    }

    @Test func warnsNearLimitAndSuggestsCheaperModelAndProvider() {
        let current = usage(90, 30)
        let summary = RateLimitTaskCostSummary.aggregate(
            [
                cost(model: "opus", fiveHour: 4, tokens: 50_000),
                cost(model: "opus", fiveHour: 4, tokens: 50_000),
                cost(model: "sonnet", fiveHour: 1, tokens: 50_000),
                cost(model: "sonnet", fiveHour: 1, tokens: 50_000),
            ],
            current: current
        )
        let codex = context(RateLimitTaskCostSummary(), usage: usage(10, 5), provider: "codex")
        let advice = RateLimitAdvisor.advise(
            context: context(summary, usage: current),
            model: "opus",
            alternatives: [codex],
            now: now
        )
        #expect(advice?.severity == .warning)
        #expect(advice?.reasons.first?.contains("2 more opus tasks") == true)
        #expect(advice?.suggestions.contains { $0.action == .switchModel("sonnet") } == true)
        #expect(advice?.suggestions.contains { $0.action == .switchProvider("codex") } == true)
    }

    @Test func noAdviceWhenLimitsAreComfortable() {
        let current = usage(10, 5)
        let summary = RateLimitTaskCostSummary.aggregate([cost(fiveHour: 1), cost(fiveHour: 1)], current: current)
        #expect(RateLimitAdvisor.advise(context: context(summary, usage: current), model: nil, now: now) == nil)
    }

    @Test func warnsWhenPaceExhaustsLimitBeforeReset() {
        // 1 hour into the 5-hour window with 60% used: runs out ~40 min in the future,
        // well before the reset 4 hours away.
        let current = usage(60, 5, fiveHourResetsAt: now.addingTimeInterval(4 * 3600))
        let advice = RateLimitAdvisor.advise(
            context: context(RateLimitTaskCostSummary(), usage: current),
            model: nil,
            now: now
        )
        #expect(advice?.severity == .warning)
        #expect(advice?.reasons.contains { $0.contains("At this pace the 5-hour limit") } == true)
    }

    @Test func tipsSmallerModelForLightTasksOnPremiumModel() {
        let current = usage(30, 10)
        let summary = RateLimitTaskCostSummary.aggregate(
            [
                cost(model: "opus", fiveHour: 3, tokens: 10_000),
                cost(model: "opus", fiveHour: 3, tokens: 10_000),
                cost(model: "opus", fiveHour: 3, tokens: 10_000),
                cost(model: "sonnet", fiveHour: 1, tokens: 200_000),
                cost(model: "sonnet", fiveHour: 1, tokens: 200_000),
            ],
            current: current
        )
        let advice = RateLimitAdvisor.advise(context: context(summary, usage: current), model: "opus", now: now)
        #expect(advice?.severity == .info)
        #expect(advice?.suggestions.first?.action == .switchModel("sonnet"))
    }

    @Test func detectsPlansWithoutFiveHourLimit() {
        let reset = now.addingTimeInterval(6 * 24 * 3600)
        #expect(!usage(20, 20, fiveHourResetsAt: reset, sevenDayResetsAt: reset).hasFiveHourLimit)
        #expect(usage(20, 20, fiveHourResetsAt: now.addingTimeInterval(3600), sevenDayResetsAt: reset).hasFiveHourLimit)
        #expect(usage(30, 20, fiveHourResetsAt: reset, sevenDayResetsAt: reset).hasFiveHourLimit)
        #expect(usage(20, 20).hasFiveHourLimit)
    }

    @Test func skipsFiveHourAdviceWithoutFiveHourLimit() {
        // 90% of a single weekly window, mirrored into both readings.
        let reset = now.addingTimeInterval(24 * 3600)
        let current = usage(90, 90, fiveHourResetsAt: reset, sevenDayResetsAt: reset)
        let advice = RateLimitAdvisor.advise(
            context: context(RateLimitTaskCostSummary(), usage: current),
            model: nil,
            now: now
        )
        #expect(advice?.reasons.contains { $0.contains("5-hour") } == false)
        #expect(advice?.reasons.contains { $0.contains("7-day") } == true)
        #expect(advice?.suggestions.contains { if case .waitForReset = $0.action { true } else { false } } == false)
    }

    @Test func weeklyCostGroupsByWeekAndPrefersSoloTasks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let costs = [
            // This week: a solo task and a concurrent one that is ignored.
            cost(fiveHour: 2, sevenDay: 1, tokens: 1_000_000),
            cost(fiveHour: 9, sevenDay: 9, tokens: 1_000_000, concurrent: 1),
            // Two weeks ago: only concurrent tasks, so they are used.
            cost(fiveHour: 1, sevenDay: nil, tokens: 500_000, concurrent: 1, minutesAgo: 14 * 24 * 60),
            // Unmeasured and token-less tasks are skipped.
            cost(fiveHour: nil, sevenDay: nil, tokens: 1_000_000),
            cost(fiveHour: 5, tokens: 0),
        ]
        let weeks = RateLimitWeeklyCost.weekly(costs, calendar: calendar)
        #expect(weeks.count == 2)
        #expect(weeks.first?.fiveHourPerMillionTokens == 2)
        #expect(weeks.first?.sevenDayPerMillionTokens == nil)
        #expect(weeks.last?.taskCount == 1)
        #expect(weeks.last?.fiveHourPerMillionTokens == 2)
        #expect(weeks.last?.sevenDayPerMillionTokens == 1)
    }
}
