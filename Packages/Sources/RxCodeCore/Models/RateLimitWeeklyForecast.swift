import Foundation

/// Account-wide forecast calibrated from isolated task costs and daily activity.
/// This is an estimate: provider accounting and work outside RxCode can differ.
public struct RateLimitWeeklyForecast: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case insufficientData
        case exhausted
        case lastsUntilReset
        case depletes(Date)
    }

    public var outcome: Outcome = .insufficientData
    public var observedDays: Int = 0
    public var dailyTokens: Double = 0
    public var dailySessionSeconds: Double = 0
    public var dailyPercent: Double = 0

    public init() {}

    public static func estimate(
        providerRaw: String,
        usage: RateLimitUsage?,
        costs: [RateLimitTaskCostSnapshot],
        dailyBuckets: [UsageStatBucketSnapshot],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Self {
        var result = Self()
        guard let usage, usage.sevenDayPercent.isFinite,
              let reset = usage.sevenDayResetsAt, reset > now,
              reset.timeIntervalSince(now) <= 7 * 86_400 else { return result }
        if usage.sevenDayPercent >= 100 {
            result.outcome = .exhausted
            return result
        }
        guard usage.sevenDayPercent >= 0 else { return result }
        // Complete calendar days avoid extrapolating a morning burst over 24h.
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let buckets = dailyBuckets.filter {
            $0.providerRaw == providerRaw && $0.bucketStart >= cutoff && $0.bucketStart < today
        }
        let activeDays = Set(buckets.map { calendar.startOfDay(for: $0.bucketStart) })
        guard activeDays.count >= 2, let first = activeDays.min() else { return result }
        let days = calendar.dateComponents([.day], from: first, to: today).day ?? 0
        guard days >= 2 else { return result }
        result.observedDays = days
        // Include idle days between the first observed day and today.
        let measured = costs.filter {
            $0.providerRaw == providerRaw && $0.isIsolated && $0.startedAt >= cutoff && $0.endedAt <= now
                && $0.endedAt >= $0.startedAt
                && ($0.sevenDayDelta.map { $0.isFinite && $0 >= 0 && $0 <= 100 } ?? false)
        }
        guard measured.count >= 3 else { return result }
        let byModel = Dictionary(grouping: measured, by: \.model)
        var projectedPoints: Double = 0
        for bucket in buckets {
            let tokens = Double(max(0, bucket.inputTokens)) + Double(max(0, bucket.outputTokens))
                + Double(max(0, bucket.cacheCreationTokens))
            let seconds = bucket.sessionSeconds
            guard seconds.isFinite, seconds >= 0 else { return Self() }
            result.dailyTokens += tokens / Double(days)
            result.dailySessionSeconds += seconds / Double(days)
            guard tokens > 0 || seconds > 0 || bucket.turns > 0 else { continue }
            // Do not apply one model's limit price to an unmeasured model.
            guard let modelCosts = byModel[bucket.model], modelCosts.count >= 3 else { return result }
            let tokenCosts = modelCosts.filter { $0.tokens > 0 }
            let measuredTokens = tokenCosts.reduce(0.0) { $0 + Double($1.tokens) }
            if tokens > 0, tokenCosts.count >= 3, measuredTokens > 0 {
                projectedPoints += tokens * tokenCosts.reduce(0) { $0 + ($1.sevenDayDelta ?? 0) } / measuredTokens
            } else {
                let timed = modelCosts.filter { $0.endedAt > $0.startedAt }
                let duration = timed.reduce(0.0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) }
                guard seconds > 0, timed.count >= 3, duration > 0 else { return result }
                projectedPoints += seconds * timed.reduce(0) { $0 + ($1.sevenDayDelta ?? 0) } / duration
            }
        }
        result.dailyPercent = projectedPoints / Double(days)
        // Rounded zero deltas are not evidence of unlimited usage.
        guard result.dailyPercent.isFinite, result.dailyPercent > 0 else { return result }
        let remaining = (100 - usage.sevenDayPercent) / result.dailyPercent * 86_400
        guard remaining.isFinite else { return result }
        result.outcome = remaining < reset.timeIntervalSince(now)
            ? .depletes(now.addingTimeInterval(remaining)) : .lastsUntilReset
        return result
    }
}
