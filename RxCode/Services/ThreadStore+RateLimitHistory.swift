import Foundation
import os
import SwiftData
import RxCodeCore

/// Persisted usage-limit history (5-hour / 7-day percentages over time) and
/// per-task limit costs, shown on the briefing page.
extension ThreadStore {
    /// Both tables back the briefing usage windows (up to 365 days); keep a
    /// small margin, matching the daily usage buckets.
    static let rateLimitHistoryRetention: TimeInterval = dailyUsageRetention

    /// Stores `usage` unless it adds nothing over the provider's latest sample.
    /// Returns whether a row was written.
    @discardableResult
    func recordRateLimitSample(_ usage: RateLimitUsage, providerRaw: String, at date: Date = .now) -> Bool {
        var descriptor = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.providerRaw == providerRaw },
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        let previous = (try? context.fetch(descriptor))?.first?.toPoint()
        guard RateLimitSample.shouldRecord(previous: previous, usage: usage, at: date) else { return false }
        context.insert(RateLimitSample(providerRaw: providerRaw, usage: usage, capturedAt: date))
        save()
        return true
    }

    /// Samples for one provider since `since`, oldest first.
    func rateLimitSamples(providerRaw: String, since: Date) -> [RateLimitSamplePoint] {
        let descriptor = FetchDescriptor<RateLimitSample>(
            predicate: #Predicate { $0.providerRaw == providerRaw && $0.capturedAt >= since },
            sortBy: [SortDescriptor(\.capturedAt)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { $0.toPoint() }
    }

    func recordRateLimitTaskCost(_ cost: RateLimitTaskCost) {
        context.insert(cost)
        save()
    }

    /// Task costs for one provider that finished since `since`.
    func rateLimitTaskCosts(providerRaw: String, since: Date) -> [RateLimitTaskCostSnapshot] {
        let descriptor = FetchDescriptor<RateLimitTaskCost>(
            predicate: #Predicate { $0.providerRaw == providerRaw && $0.endedAt >= since },
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map { $0.toSnapshot() }
    }

    /// Deletes samples and task costs older than the retention window.
    func pruneRateLimitHistory(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.rateLimitHistoryRetention)
        do {
            try context.delete(model: RateLimitSample.self, where: #Predicate { $0.capturedAt < cutoff })
            try context.delete(model: RateLimitTaskCost.self, where: #Predicate { $0.endedAt < cutoff })
            save()
        } catch {
            logger.error("Rate limit history prune failed: \(error.localizedDescription)")
        }
    }
}
