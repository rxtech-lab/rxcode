import Foundation
import SwiftData

/// Pre-aggregated agent usage for one time bucket, keyed by project, provider,
/// and model. Rows are incremented as each agent turn finishes, so the
/// briefing statistics panel only sums a small number of rows instead of
/// re-scanning every thread.
///
/// Two granularities are kept: hourly rows (pruned after a few days) back the
/// precise 24-hour window, and daily rows back the 7/30/365-day windows.
@Model
public final class UsageStatBucket {
    /// `"<granularity>|<bucketStart>|<projectId>|<provider>|<model>"`.
    @Attribute(.unique) public var id: String
    public var granularityRaw: String
    public var bucketStart: Date
    public var projectId: UUID?
    public var providerRaw: String
    /// Model id as reported by the backend; empty string when unknown.
    public var model: String
    public var sessionSeconds: Double = 0
    public var turns: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var updatedAt: Date

    public init(
        granularity: UsageStatGranularity,
        bucketStart: Date,
        projectId: UUID?,
        providerRaw: String,
        model: String,
        updatedAt: Date = .now
    ) {
        self.id = Self.makeId(
            granularity: granularity,
            bucketStart: bucketStart,
            projectId: projectId,
            providerRaw: providerRaw,
            model: model
        )
        self.granularityRaw = granularity.rawValue
        self.bucketStart = bucketStart
        self.projectId = projectId
        self.providerRaw = providerRaw
        self.model = model
        self.updatedAt = updatedAt
    }

    public static func makeId(
        granularity: UsageStatGranularity,
        bucketStart: Date,
        projectId: UUID?,
        providerRaw: String,
        model: String
    ) -> String {
        let start = Int(bucketStart.timeIntervalSince1970)
        return "\(granularity.rawValue)|\(start)|\(projectId?.uuidString ?? "-")|\(providerRaw)|\(model)"
    }

    public func add(_ sample: UsageStatSample, at date: Date) {
        sessionSeconds += max(0, sample.sessionSeconds)
        turns += 1
        inputTokens += sample.inputTokens
        outputTokens += sample.outputTokens
        cacheCreationTokens += sample.cacheCreationTokens
        cacheReadTokens += sample.cacheReadTokens
        updatedAt = date
    }

    public func toSnapshot() -> UsageStatBucketSnapshot {
        UsageStatBucketSnapshot(
            bucketStart: bucketStart,
            projectId: projectId,
            providerRaw: providerRaw,
            model: model,
            sessionSeconds: sessionSeconds,
            turns: turns,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens
        )
    }
}

public enum UsageStatGranularity: String, Sendable, CaseIterable {
    case hour
    case day

    /// Start of the bucket containing `date`.
    public func bucketStart(for date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .day:
            return calendar.startOfDay(for: date)
        }
    }
}

/// One finished agent turn to fold into the usage buckets.
public struct UsageStatSample: Sendable, Equatable {
    public var projectId: UUID?
    public var providerRaw: String
    public var model: String
    public var sessionSeconds: Double
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int

    public init(
        projectId: UUID?,
        providerRaw: String,
        model: String?,
        sessionSeconds: Double,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) {
        self.projectId = projectId
        self.providerRaw = providerRaw
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.sessionSeconds = sessionSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

/// Value copy of a `UsageStatBucket` row, safe to pass off the main actor.
public struct UsageStatBucketSnapshot: Sendable, Equatable {
    public var bucketStart: Date
    public var projectId: UUID?
    public var providerRaw: String
    public var model: String
    public var sessionSeconds: Double
    public var turns: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int

    public init(
        bucketStart: Date,
        projectId: UUID?,
        providerRaw: String,
        model: String,
        sessionSeconds: Double,
        turns: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int
    ) {
        self.bucketStart = bucketStart
        self.projectId = projectId
        self.providerRaw = providerRaw
        self.model = model
        self.sessionSeconds = sessionSeconds
        self.turns = turns
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }
}

/// Selectable window for the briefing usage statistics.
public enum UsageStatsRange: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case year

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "24h"
        case .week: "7d"
        case .month: "30d"
        case .year: "365d"
        }
    }

    public var longTitle: String {
        switch self {
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        case .year: "Last 365 days"
        }
    }

    /// Bucket granularity used to answer this range.
    public var granularity: UsageStatGranularity {
        self == .day ? .hour : .day
    }

    /// Earliest bucket start included in the range ending at `now`.
    public func cutoff(now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .day:
            // Include the partially elapsed hour 24 hours ago.
            let raw = now.addingTimeInterval(-24 * 3600)
            return UsageStatGranularity.hour.bucketStart(for: raw, calendar: calendar)
                .addingTimeInterval(3600)
        case .week, .month, .year:
            let days = self == .week ? 7 : (self == .month ? 30 : 365)
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        }
    }
}

/// Aggregated statistics for one range, computed from bucket snapshots.
public struct UsageStatsSummary: Sendable, Equatable {
    public struct Usage: Sendable, Equatable, Identifiable {
        public var providerRaw: String
        public var model: String
        public var turns: Int
        public var sessionSeconds: Double
        public var totalTokens: Int

        public var id: String { "\(providerRaw)|\(model)" }
    }

    public var sessionSeconds: Double = 0
    public var turns: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var cacheReadTokens: Int = 0
    /// Per provider+model usage, most used first.
    public var models: [Usage] = []
    /// Per provider usage (model left empty), most used first.
    public var providers: [Usage] = []

    public init() {}

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    public var isEmpty: Bool { turns == 0 }

    public var topModel: Usage? { models.first }
    public var topProvider: Usage? { providers.first }

    /// Folds bucket snapshots into a summary. "Most used" ranks by turns, then
    /// session time, then tokens.
    public static func aggregate(_ buckets: [UsageStatBucketSnapshot]) -> UsageStatsSummary {
        var summary = UsageStatsSummary()
        var byModel: [String: Usage] = [:]
        var byProvider: [String: Usage] = [:]
        for bucket in buckets {
            let tokens = bucket.inputTokens + bucket.outputTokens
                + bucket.cacheCreationTokens + bucket.cacheReadTokens
            summary.sessionSeconds += bucket.sessionSeconds
            summary.turns += bucket.turns
            summary.inputTokens += bucket.inputTokens
            summary.outputTokens += bucket.outputTokens
            summary.cacheCreationTokens += bucket.cacheCreationTokens
            summary.cacheReadTokens += bucket.cacheReadTokens

            let modelKey = "\(bucket.providerRaw)|\(bucket.model)"
            var model = byModel[modelKey]
                ?? Usage(providerRaw: bucket.providerRaw, model: bucket.model, turns: 0, sessionSeconds: 0, totalTokens: 0)
            model.turns += bucket.turns
            model.sessionSeconds += bucket.sessionSeconds
            model.totalTokens += tokens
            byModel[modelKey] = model

            var provider = byProvider[bucket.providerRaw]
                ?? Usage(providerRaw: bucket.providerRaw, model: "", turns: 0, sessionSeconds: 0, totalTokens: 0)
            provider.turns += bucket.turns
            provider.sessionSeconds += bucket.sessionSeconds
            provider.totalTokens += tokens
            byProvider[bucket.providerRaw] = provider
        }
        summary.models = byModel.values.sorted(by: rank)
        summary.providers = byProvider.values.sorted(by: rank)
        return summary
    }

    private static func rank(_ lhs: Usage, _ rhs: Usage) -> Bool {
        if lhs.turns != rhs.turns { return lhs.turns > rhs.turns }
        if lhs.sessionSeconds != rhs.sessionSeconds { return lhs.sessionSeconds > rhs.sessionSeconds }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.id < rhs.id
    }
}
