import Foundation
import SwiftData

/// One point-in-time reading of a provider's 5-hour / 7-day usage limits.
/// Written whenever a fresh reading arrives (throttled by
/// `RateLimitSample.shouldRecord`) and plotted as the usage-limit history
/// line chart on the briefing page.
@Model
public final class RateLimitSample {
    @Attribute(.unique) public var id: UUID
    public var providerRaw: String
    public var capturedAt: Date
    public var fiveHourPercent: Double
    public var sevenDayPercent: Double
    public var fiveHourResetsAt: Date?
    public var sevenDayResetsAt: Date?

    public init(providerRaw: String, usage: RateLimitUsage, capturedAt: Date = .now) {
        self.id = UUID()
        self.providerRaw = providerRaw
        self.capturedAt = capturedAt
        self.fiveHourPercent = usage.fiveHourPercent
        self.sevenDayPercent = usage.sevenDayPercent
        self.fiveHourResetsAt = usage.fiveHourResetsAt
        self.sevenDayResetsAt = usage.sevenDayResetsAt
    }

    /// Readings closer together than this are only stored when a value changed.
    public static let minimumUnchangedInterval: TimeInterval = 10 * 60

    /// Whether `usage` read at `date` adds information over the `previous`
    /// stored sample. Changed values are always kept so the chart shows every
    /// step; unchanged ones only every `minimumUnchangedInterval`.
    public static func shouldRecord(previous: RateLimitSamplePoint?, usage: RateLimitUsage, at date: Date) -> Bool {
        guard let previous else { return true }
        if previous.fiveHourPercent != usage.fiveHourPercent
            || previous.sevenDayPercent != usage.sevenDayPercent {
            return true
        }
        return date.timeIntervalSince(previous.capturedAt) >= minimumUnchangedInterval
    }

    public func toPoint() -> RateLimitSamplePoint {
        RateLimitSamplePoint(
            providerRaw: providerRaw,
            capturedAt: capturedAt,
            fiveHourPercent: fiveHourPercent,
            sevenDayPercent: sevenDayPercent
        )
    }
}

/// Value copy of a `RateLimitSample` row.
public struct RateLimitSamplePoint: Sendable, Equatable {
    public var providerRaw: String
    public var capturedAt: Date
    public var fiveHourPercent: Double
    public var sevenDayPercent: Double

    public init(providerRaw: String, capturedAt: Date, fiveHourPercent: Double, sevenDayPercent: Double) {
        self.providerRaw = providerRaw
        self.capturedAt = capturedAt
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
    }
}

/// How much of a provider's usage limits one agent task (a prompt through its
/// final `result`) consumed, measured as the change in the limit percentages
/// read before and after the task.
@Model
public final class RateLimitTaskCost {
    @Attribute(.unique) public var id: UUID
    public var providerRaw: String
    /// Model id as reported by the backend; empty string when unknown.
    public var model: String
    public var projectId: UUID?
    public var threadId: String
    public var threadTitle: String
    public var startedAt: Date
    public var endedAt: Date
    /// Percentage points of the 5-hour limit used; nil when the window reset
    /// mid-task, so the change can't be attributed.
    public var fiveHourDelta: Double?
    /// Percentage points of the 7-day limit used; nil when unattributable.
    public var sevenDayDelta: Double?
    /// Other tasks on the same provider running at the same time. Their usage
    /// lands in the same limit, so overlapping measurements are less precise.
    public var concurrentRuns: Int = 0
    /// Uncached tokens the task processed (input + output + cache writes).
    /// Cache reads are left out since they barely count toward limits.
    public var tokens: Int = 0

    public init(
        providerRaw: String,
        model: String?,
        projectId: UUID?,
        threadId: String,
        threadTitle: String,
        startedAt: Date,
        endedAt: Date,
        fiveHourDelta: Double?,
        sevenDayDelta: Double?,
        concurrentRuns: Int,
        tokens: Int = 0
    ) {
        self.id = UUID()
        self.providerRaw = providerRaw
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.projectId = projectId
        self.threadId = threadId
        self.threadTitle = threadTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.fiveHourDelta = fiveHourDelta
        self.sevenDayDelta = sevenDayDelta
        self.concurrentRuns = concurrentRuns
        self.tokens = tokens
    }

    public func toSnapshot() -> RateLimitTaskCostSnapshot {
        RateLimitTaskCostSnapshot(
            id: id,
            providerRaw: providerRaw,
            model: model,
            projectId: projectId,
            threadId: threadId,
            threadTitle: threadTitle,
            startedAt: startedAt,
            endedAt: endedAt,
            fiveHourDelta: fiveHourDelta,
            sevenDayDelta: sevenDayDelta,
            concurrentRuns: concurrentRuns,
            tokens: tokens
        )
    }
}

/// Value copy of a `RateLimitTaskCost` row.
public struct RateLimitTaskCostSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var providerRaw: String
    public var model: String
    public var projectId: UUID?
    public var threadId: String
    public var threadTitle: String
    public var startedAt: Date
    public var endedAt: Date
    public var fiveHourDelta: Double?
    public var sevenDayDelta: Double?
    public var concurrentRuns: Int
    public var tokens: Int

    public init(
        id: UUID = UUID(),
        providerRaw: String,
        model: String = "",
        projectId: UUID? = nil,
        threadId: String = "",
        threadTitle: String = "",
        startedAt: Date,
        endedAt: Date,
        fiveHourDelta: Double?,
        sevenDayDelta: Double?,
        concurrentRuns: Int = 0,
        tokens: Int = 0
    ) {
        self.id = id
        self.providerRaw = providerRaw
        self.model = model
        self.projectId = projectId
        self.threadId = threadId
        self.threadTitle = threadTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.fiveHourDelta = fiveHourDelta
        self.sevenDayDelta = sevenDayDelta
        self.concurrentRuns = concurrentRuns
        self.tokens = tokens
    }

    public var isIsolated: Bool { concurrentRuns == 0 }
}

/// Change in usage-limit percentages between two readings.
public enum RateLimitDelta {
    /// Reset times further apart than this mean the window rolled over.
    static let resetTolerance: TimeInterval = 5 * 60

    /// Percentage points used between `before` and `after`, per window. A
    /// window yields nil when it reset in between (its reset time moved or its
    /// percentage dropped), since the usage can't be attributed.
    public static func between(
        _ before: RateLimitUsage,
        _ after: RateLimitUsage
    ) -> (fiveHour: Double?, sevenDay: Double?) {
        (
            delta(before.fiveHourPercent, after.fiveHourPercent, before.fiveHourResetsAt, after.fiveHourResetsAt),
            delta(before.sevenDayPercent, after.sevenDayPercent, before.sevenDayResetsAt, after.sevenDayResetsAt)
        )
    }

    private static func delta(_ before: Double, _ after: Double, _ beforeReset: Date?, _ afterReset: Date?) -> Double? {
        if let beforeReset, let afterReset,
           abs(afterReset.timeIntervalSince(beforeReset)) > resetTolerance {
            return nil
        }
        guard after >= before else { return nil }
        return after - before
    }
}

/// Per-task limit cost statistics for one provider, plus how many more tasks
/// of average cost fit in what's left of each window.
public struct RateLimitTaskCostSummary: Sendable, Equatable {
    public enum Estimate: Sendable, Equatable {
        /// No measured tasks for this window yet.
        case insufficientData
        /// Tasks measured so far didn't move the limit at all.
        case unbounded
        case tasks(Int)
    }

    /// Isolated samples are preferred once there are at least this many.
    public static let minimumIsolatedSamples = 3

    /// Every measured task in the range, newest first.
    public var tasks: [RateLimitTaskCostSnapshot] = []
    /// Tasks the averages and estimates are based on.
    public var sampleCount: Int = 0
    /// True when concurrent runs were excluded from the averages.
    public var usesIsolatedSamplesOnly = false
    public var averageFiveHour: Double?
    public var averageSevenDay: Double?
    /// Highest 5-hour cost (7-day breaks ties).
    public var mostExpensive: RateLimitTaskCostSnapshot?
    /// Lowest 5-hour cost (7-day breaks ties).
    public var leastExpensive: RateLimitTaskCostSnapshot?
    public var remainingFiveHour: Estimate = .insufficientData
    public var remainingSevenDay: Estimate = .insufficientData
    /// Per-model costs and estimates, most measured tasks first.
    public var models: [ModelStats] = []

    /// Limit cost and remaining-task estimates for one model.
    public struct ModelStats: Sendable, Equatable, Identifiable {
        public var model: String
        public var sampleCount: Int
        public var averageFiveHour: Double?
        public var averageSevenDay: Double?
        /// Mean uncached tokens per task.
        public var averageTokens: Double
        /// Median uncached tokens per task — how heavy this model's tasks are.
        public var medianTokens: Double
        /// 5-hour percentage points per million uncached tokens. Larger, more
        /// capable models draw down limits faster for the same tokens, so this
        /// ranks the provider's models by tier.
        public var fiveHourPerMillionTokens: Double?
        /// 7-day percentage points per million uncached tokens.
        public var sevenDayPerMillionTokens: Double? = nil
        public var remainingFiveHour: Estimate
        public var remainingSevenDay: Estimate

        public var id: String { model }
    }

    public init() {}

    /// Stats for `model`, matching aliases such as `opus` against full ids
    /// such as `claude-opus-5-5`.
    public func stats(forModel model: String?) -> ModelStats? {
        guard let needle = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !needle.isEmpty
        else { return nil }
        if let exact = models.first(where: { $0.model.lowercased() == needle }) { return exact }
        return models.first { candidate in
            let id = candidate.model.lowercased()
            return !id.isEmpty && (id.contains(needle) || needle.contains(id))
        }
    }

    public var isEmpty: Bool { tasks.isEmpty }

    public static func aggregate(
        _ costs: [RateLimitTaskCostSnapshot],
        current: RateLimitUsage?
    ) -> RateLimitTaskCostSummary {
        var summary = RateLimitTaskCostSummary()
        summary.tasks = costs.sorted { $0.endedAt > $1.endedAt }

        let measured = summary.tasks.filter { $0.fiveHourDelta != nil || $0.sevenDayDelta != nil }
        let isolated = measured.filter(\.isIsolated)
        let basis: [RateLimitTaskCostSnapshot]
        if isolated.count >= minimumIsolatedSamples, isolated.count < measured.count {
            basis = isolated
            summary.usesIsolatedSamplesOnly = true
        } else {
            basis = measured
        }
        summary.sampleCount = basis.count
        summary.averageFiveHour = average(basis.compactMap(\.fiveHourDelta))
        summary.averageSevenDay = average(basis.compactMap(\.sevenDayDelta))

        let ranked = basis.sorted(by: costsMore)
        summary.mostExpensive = ranked.first
        summary.leastExpensive = ranked.count > 1 ? ranked.last : nil

        if let current {
            summary.remainingFiveHour = estimate(used: current.fiveHourPercent, average: summary.averageFiveHour)
            summary.remainingSevenDay = estimate(used: current.sevenDayPercent, average: summary.averageSevenDay)
        }
        summary.models = Dictionary(grouping: basis, by: \.model)
            .map { model, tasks in modelStats(model: model, tasks: tasks, current: current) }
            .sorted {
                if $0.sampleCount != $1.sampleCount { return $0.sampleCount > $1.sampleCount }
                return $0.model < $1.model
            }
        return summary
    }

    private static func modelStats(
        model: String,
        tasks: [RateLimitTaskCostSnapshot],
        current: RateLimitUsage?
    ) -> ModelStats {
        let fiveHour = average(tasks.compactMap(\.fiveHourDelta))
        let sevenDay = average(tasks.compactMap(\.sevenDayDelta))
        let tokens = tasks.map { Double($0.tokens) }
        let perMillion = perMillionTokens(tasks, delta: \.fiveHourDelta)
        let sevenDayPerMillion = perMillionTokens(tasks, delta: \.sevenDayDelta)
        return ModelStats(
            model: model,
            sampleCount: tasks.count,
            averageFiveHour: fiveHour,
            averageSevenDay: sevenDay,
            averageTokens: average(tokens) ?? 0,
            medianTokens: median(tokens) ?? 0,
            fiveHourPerMillionTokens: perMillion,
            sevenDayPerMillionTokens: sevenDayPerMillion,
            remainingFiveHour: current.map { estimate(used: $0.fiveHourPercent, average: fiveHour) } ?? .insufficientData,
            remainingSevenDay: current.map { estimate(used: $0.sevenDayPercent, average: sevenDay) } ?? .insufficientData
        )
    }

    /// Percentage points of a limit per million tokens, over the tasks whose
    /// cost in that limit could be measured.
    static func perMillionTokens(
        _ tasks: [RateLimitTaskCostSnapshot],
        delta: KeyPath<RateLimitTaskCostSnapshot, Double?>
    ) -> Double? {
        let measured = tasks.filter { $0[keyPath: delta] != nil }
        let tokens = measured.reduce(0) { $0 + $1.tokens }
        guard tokens > 0 else { return nil }
        return measured.reduce(0) { $0 + ($1[keyPath: delta] ?? 0) } / Double(tokens) * 1_000_000
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Whole tasks of `average` cost that fit in the unused part of a window.
    public static func estimate(used: Double, average: Double?) -> Estimate {
        guard let average else { return .insufficientData }
        guard average > 0 else { return .unbounded }
        let left = max(0, 100 - used)
        return .tasks(Int((left / average).rounded(.down)))
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func costsMore(_ lhs: RateLimitTaskCostSnapshot, _ rhs: RateLimitTaskCostSnapshot) -> Bool {
        let lhsFive = lhs.fiveHourDelta ?? -1
        let rhsFive = rhs.fiveHourDelta ?? -1
        if lhsFive != rhsFive { return lhsFive > rhsFive }
        let lhsSeven = lhs.sevenDayDelta ?? -1
        let rhsSeven = rhs.sevenDayDelta ?? -1
        if lhsSeven != rhsSeven { return lhsSeven > rhsSeven }
        return lhs.endedAt > rhs.endedAt
    }
}

/// Limit used per million tokens for one calendar week, to show whether a
/// provider's limits are getting tighter or looser over time.
public struct RateLimitWeeklyCost: Sendable, Equatable, Identifiable {
    public var weekStart: Date
    /// Tasks the week's figures are based on.
    public var taskCount: Int
    /// Uncached tokens across those tasks (input + output + cache writes).
    public var tokens: Int
    public var fiveHourPerMillionTokens: Double?
    public var sevenDayPerMillionTokens: Double?

    public var id: Date { weekStart }

    /// Groups measured tasks by the calendar week they finished in, oldest
    /// week first. Tasks that ran alone are preferred when a week has any,
    /// since concurrent tasks share one limit reading.
    public static func weekly(
        _ costs: [RateLimitTaskCostSnapshot],
        calendar: Calendar = .current
    ) -> [RateLimitWeeklyCost] {
        let measured = costs.filter { ($0.fiveHourDelta != nil || $0.sevenDayDelta != nil) && $0.tokens > 0 }
        let byWeek = Dictionary(grouping: measured) { cost in
            calendar.dateInterval(of: .weekOfYear, for: cost.endedAt)?.start ?? cost.endedAt
        }
        return byWeek.map { weekStart, tasks in
            let isolated = tasks.filter(\.isIsolated)
            let basis = isolated.isEmpty ? tasks : isolated
            return RateLimitWeeklyCost(
                weekStart: weekStart,
                taskCount: basis.count,
                tokens: basis.reduce(0) { $0 + $1.tokens },
                fiveHourPerMillionTokens: RateLimitTaskCostSummary.perMillionTokens(basis, delta: \.fiveHourDelta),
                sevenDayPerMillionTokens: RateLimitTaskCostSummary.perMillionTokens(basis, delta: \.sevenDayDelta)
            )
        }
        .sorted { $0.weekStart < $1.weekStart }
    }
}
