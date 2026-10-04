import Foundation
import SwiftData
import Testing
@testable import RxCodeCore

@Suite("Usage statistics")
struct UsageStatsTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func snapshot(
        provider: String = "claudeCode",
        model: String,
        seconds: Double = 60,
        turns: Int = 1,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0
    ) -> UsageStatBucketSnapshot {
        UsageStatBucketSnapshot(
            bucketStart: date(2026, 9, 27),
            projectId: nil,
            providerRaw: provider,
            model: model,
            sessionSeconds: seconds,
            turns: turns,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: cacheRead
        )
    }

    @Test("Aggregates totals and ranks the most used model and provider")
    func aggregate() {
        let summary = UsageStatsSummary.aggregate([
            snapshot(model: "claude-opus-5-5", seconds: 120, turns: 2, input: 100, output: 50),
            snapshot(model: "claude-opus-5-5", seconds: 30, turns: 1, input: 10, output: 5, cacheRead: 1000),
            snapshot(provider: "codex", model: "gpt-5", seconds: 600, turns: 2, input: 1, output: 1),
            snapshot(provider: "codex", model: "gpt-5-mini", seconds: 10, turns: 1),
        ])

        #expect(summary.turns == 6)
        #expect(summary.sessionSeconds == 760)
        #expect(summary.inputTokens == 111)
        #expect(summary.outputTokens == 56)
        #expect(summary.totalTokens == 1167)
        #expect(summary.topModel?.model == "claude-opus-5-5")
        #expect(summary.topModel?.turns == 3)
        // Codex has 3 turns too but more session time, so it wins the tie.
        #expect(summary.topProvider?.providerRaw == "codex")
    }

    @Test("Empty input yields an empty summary")
    func empty() {
        let summary = UsageStatsSummary.aggregate([])
        #expect(summary.isEmpty)
        #expect(summary.topModel == nil)
        #expect(summary.totalTokens == 0)
    }

    @Test("Range cutoffs and granularity")
    func cutoffs() {
        let now = date(2026, 9, 27, 15, 30)
        #expect(UsageStatsRange.day.granularity == .hour)
        #expect(UsageStatsRange.week.granularity == .day)
        #expect(UsageStatsRange.day.cutoff(now: now, calendar: calendar) == date(2026, 9, 26, 16))
        #expect(UsageStatsRange.week.cutoff(now: now, calendar: calendar) == date(2026, 9, 21))
        #expect(UsageStatsRange.month.cutoff(now: now, calendar: calendar) == date(2026, 8, 29))
        #expect(UsageStatsRange.year.cutoff(now: now, calendar: calendar) == date(2025, 9, 28))
    }

    @Test("Bucket rows accumulate samples")
    func bucketAccumulates() {
        let start = UsageStatGranularity.hour.bucketStart(for: date(2026, 9, 27, 10, 45), calendar: calendar)
        #expect(start == date(2026, 9, 27, 10))
        let bucket = UsageStatBucket(
            granularity: .hour,
            bucketStart: start,
            projectId: nil,
            providerRaw: "claudeCode",
            model: "claude-opus-5-5"
        )
        let sample = UsageStatSample(
            projectId: nil,
            providerRaw: "claudeCode",
            model: " claude-opus-5-5 ",
            sessionSeconds: 42,
            inputTokens: 10,
            outputTokens: 20,
            cacheCreationTokens: 3,
            cacheReadTokens: 4
        )
        #expect(sample.model == "claude-opus-5-5")
        bucket.add(sample, at: .now)
        bucket.add(sample, at: .now)
        let snap = bucket.toSnapshot()
        #expect(snap.turns == 2)
        #expect(snap.sessionSeconds == 84)
        #expect(snap.inputTokens == 20)
        #expect(snap.outputTokens == 40)
        #expect(snap.cacheCreationTokens == 6)
        #expect(snap.cacheReadTokens == 8)
    }
}
