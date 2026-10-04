import Foundation
import os
import SwiftData
import RxCodeCore

/// Pre-aggregated agent usage statistics (model, session time, tokens) shown
/// on the briefing page. Each finished turn increments one hourly and one
/// daily `UsageStatBucket`, so reads only sum already-aggregated rows.
extension ThreadStore {
    /// Hourly rows only back the 24-hour window; keep a small margin.
    static let hourlyUsageRetention: TimeInterval = 3 * 24 * 3600
    /// Daily rows back windows up to 365 days; keep a small margin.
    static let dailyUsageRetention: TimeInterval = 400 * 24 * 3600

    func recordUsage(_ sample: UsageStatSample, at date: Date = .now, calendar: Calendar = .current) {
        for granularity in UsageStatGranularity.allCases {
            let start = granularity.bucketStart(for: date, calendar: calendar)
            let id = UsageStatBucket.makeId(
                granularity: granularity,
                bucketStart: start,
                projectId: sample.projectId,
                providerRaw: sample.providerRaw,
                model: sample.model
            )
            var descriptor = FetchDescriptor<UsageStatBucket>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let existing = (try? context.fetch(descriptor))?.first {
                existing.add(sample, at: date)
            } else {
                let row = UsageStatBucket(
                    granularity: granularity,
                    bucketStart: start,
                    projectId: sample.projectId,
                    providerRaw: sample.providerRaw,
                    model: sample.model,
                    updatedAt: date
                )
                row.add(sample, at: date)
                context.insert(row)
            }
        }
        save()
    }

    /// Bucket snapshots covering `range` ending at `now`. When `projectIds` is
    /// non-empty, only those projects' usage is returned.
    func usageBuckets(
        range: UsageStatsRange,
        projectIds: Set<UUID> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [UsageStatBucketSnapshot] {
        let granularity = range.granularity.rawValue
        let cutoff = range.cutoff(now: now, calendar: calendar)
        let descriptor = FetchDescriptor<UsageStatBucket>(predicate: #Predicate {
            $0.granularityRaw == granularity && $0.bucketStart >= cutoff
        })
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.compactMap { row in
            if !projectIds.isEmpty {
                guard let projectId = row.projectId, projectIds.contains(projectId) else { return nil }
            }
            return row.toSnapshot()
        }
    }

    func usageSummary(
        range: UsageStatsRange,
        projectIds: Set<UUID> = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> UsageStatsSummary {
        UsageStatsSummary.aggregate(
            usageBuckets(range: range, projectIds: projectIds, now: now, calendar: calendar)
        )
    }

    /// Deletes buckets older than their granularity's retention window.
    func pruneUsageBuckets(now: Date = .now) {
        let hourRaw = UsageStatGranularity.hour.rawValue
        let dayRaw = UsageStatGranularity.day.rawValue
        let hourCutoff = now.addingTimeInterval(-Self.hourlyUsageRetention)
        let dayCutoff = now.addingTimeInterval(-Self.dailyUsageRetention)
        do {
            try context.delete(model: UsageStatBucket.self, where: #Predicate {
                ($0.granularityRaw == hourRaw && $0.bucketStart < hourCutoff)
                    || ($0.granularityRaw == dayRaw && $0.bucketStart < dayCutoff)
            })
            save()
        } catch {
            logger.error("Usage bucket prune failed: \(error.localizedDescription)")
        }
    }
}
