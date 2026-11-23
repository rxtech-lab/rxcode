import Foundation
import os
import SwiftData
import RxCodeCore

/// Persisted usage-limit history (5-hour / 7-day percentages over time) and
/// per-task limit costs, shown in briefings and finished chats.
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

    @discardableResult
    func renameRateLimitTaskCosts(from oldId: String, to newId: String) -> Bool {
        let descriptor = FetchDescriptor<RateLimitTaskCost>(predicate: #Predicate { $0.threadId == oldId })
        guard let costs = try? context.fetch(descriptor), !costs.isEmpty else { return false }
        for cost in costs { cost.threadId = newId }
        save()
        return true
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

/// Recorded consumption of one provider's limits across the turns in a thread.
nonisolated struct ThreadRateLimitUsage: Sendable {
    struct Window: Sendable {
        let percent: Double?
        let isPartial: Bool
    }

    let provider: AgentProvider
    let fiveHour: Window
    let sevenDay: Window

    init(provider: AgentProvider, costs: [RateLimitTaskCost]) {
        self.provider = provider
        // Overlapping runs share account counters. Their deltas cannot be
        // attributed to this thread alone.
        let isolated = costs.filter { $0.concurrentRuns == 0 }
        func total(_ delta: KeyPath<RateLimitTaskCost, Double?>) -> Window {
            let values = isolated.compactMap { $0[keyPath: delta] }
            return Window(percent: values.isEmpty ? nil : values.reduce(0, +),
                          isPartial: values.count < costs.count)
        }
        fiveHour = total(\.fiveHourDelta)
        sevenDay = total(\.sevenDayDelta)
    }
}

extension ThreadStoreReader {
    func loadThreadRateLimitUsage(threadId: String) async -> [ThreadRateLimitUsage] {
        await read { context in
            var descriptor = FetchDescriptor<RateLimitTaskCost>(predicate: #Predicate { $0.threadId == threadId })
            descriptor.propertiesToFetch = [\.providerRaw, \.concurrentRuns, \.fiveHourDelta, \.sevenDayDelta]
            let costs = (try? context.fetch(descriptor)) ?? []
            let byProvider = Dictionary(grouping: costs, by: \.providerRaw)
            return AgentProvider.allCases.compactMap { provider in
                byProvider[provider.rawValue].map { ThreadRateLimitUsage(provider: provider, costs: $0) }
            }
        }
    }
}
