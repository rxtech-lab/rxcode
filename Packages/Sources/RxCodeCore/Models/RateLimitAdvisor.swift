import Foundation

/// Advice for the model a user is about to run: why its usage limits need
/// attention and which models or providers would stretch them further.
public struct RateLimitAdvice: Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        /// Worth knowing, e.g. a premium model used for light tasks.
        case info
        /// The limit is close or on pace to run out before it resets.
        case warning

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Suggestion: Sendable, Equatable, Identifiable {
        public enum Action: Sendable, Equatable {
            case switchModel(String)
            case switchProvider(String)
            case waitForReset(Date)
        }

        public var title: String
        public var detail: String
        public var action: Action

        public var id: String { title }
    }

    public var severity: Severity
    public var reasons: [String]
    public var suggestions: [Suggestion]

    public var headline: String { reasons.first ?? "" }

    /// Plain-text summary for hover help.
    public var tooltip: String {
        var lines = reasons
        if !suggestions.isEmpty {
            lines.append("")
            lines.append(contentsOf: suggestions.map { "• \($0.title) — \($0.detail)" })
        }
        return lines.joined(separator: "\n")
    }
}

/// Turns measured task costs and current limits into `RateLimitAdvice`.
public enum RateLimitAdvisor {
    /// Limit state and task costs for one provider.
    public struct ProviderContext: Sendable {
        public var providerRaw: String
        public var displayName: String
        public var usage: RateLimitUsage?
        public var summary: RateLimitTaskCostSummary

        public init(providerRaw: String, displayName: String, usage: RateLimitUsage?, summary: RateLimitTaskCostSummary) {
            self.providerRaw = providerRaw
            self.displayName = displayName
            self.usage = usage
            self.summary = summary
        }
    }

    /// Warn once this few tasks (or fewer) fit in a window.
    public static let nearLimitTasks = 3
    /// Warn at this share used even before task costs are known.
    public static let nearLimitPercent: Double = 90
    /// A model counts as cheaper when it uses at most this share of the
    /// current model's limit per task (or per token).
    static let cheaperRatio = 0.7
    /// Other providers are suggested while their 5-hour usage is below this.
    static let alternativeFiveHourCeiling: Double = 70
    static let alternativeSevenDayCeiling: Double = 90

    static let fiveHourWindow: TimeInterval = 5 * 3600
    static let sevenDayWindow: TimeInterval = 7 * 24 * 3600

    public static func advise(
        context: ProviderContext,
        model: String?,
        alternatives: [ProviderContext] = [],
        modelDisplayName: (String) -> String = { $0 },
        now: Date = .now
    ) -> RateLimitAdvice? {
        guard let usage = context.usage else { return nil }
        let summary = context.summary
        let current = summary.stats(forModel: model)
        let modelLabel = current.map { modelDisplayName($0.model) }
            ?? model.map(modelDisplayName)
            ?? context.displayName

        let hasFiveHour = usage.hasFiveHourLimit
        var warnings: [String] = []
        var infos: [String] = []

        // 1. Few tasks left before a limit is reached.
        let fiveHourEstimate = current?.remainingFiveHour ?? summary.remainingFiveHour
        let sevenDayEstimate = current?.remainingSevenDay ?? summary.remainingSevenDay
        if hasFiveHour, let reason = nearLimitReason(.fiveHour, used: usage.fiveHourPercent, estimate: fiveHourEstimate, model: modelLabel) {
            warnings.append(reason)
        }
        if let reason = nearLimitReason(.sevenDay, used: usage.sevenDayPercent, estimate: sevenDayEstimate, model: modelLabel) {
            warnings.append(reason)
        }

        // 2. Burning the limit faster than the window allows.
        if hasFiveHour, let early = exhaustionLead(used: usage.fiveHourPercent, resetsAt: usage.fiveHourResetsAt, window: fiveHourWindow, now: now) {
            warnings.append(String(localized: "At this pace the 5-hour limit runs out about \(formatInterval(early)) before it resets.", bundle: .module))
        }
        if let early = exhaustionLead(used: usage.sevenDayPercent, resetsAt: usage.sevenDayResetsAt, window: sevenDayWindow, now: now) {
            warnings.append(String(localized: "At this pace the 7-day limit runs out about \(formatInterval(early)) before it resets.", bundle: .module))
        }

        // 3. A premium model spent on light tasks.
        let cheaper = cheaperModels(than: current, in: summary)
        if let current, current.sampleCount >= RateLimitTaskCostSummary.minimumIsolatedSamples, !cheaper.isEmpty,
           let overallMedian = RateLimitTaskCostSummary.median(summary.tasks.map { Double($0.tokens) }.filter { $0 > 0 }),
           current.medianTokens > 0, current.medianTokens <= overallMedian {
            infos.append(String(
                localized: "Recent \(modelLabel) tasks are light (median \(formatTokens(current.medianTokens)) tokens). A smaller model could handle them for less of the limit.",
                bundle: .module
            ))
        }

        let reasons = warnings + infos
        guard !reasons.isEmpty else { return nil }

        var suggestions: [RateLimitAdvice.Suggestion] = cheaper.prefix(2).map { stats in
            let average = hasFiveHour
                ? stats.averageFiveHour.map { String(localized: "\(formatPoints($0)) of 5h per task", bundle: .module) }
                : stats.averageSevenDay.map { String(localized: "\(formatPoints($0)) of 7d per task", bundle: .module) }
            var detail = average ?? String(localized: "Lower limit cost per token", bundle: .module)
            if case .tasks(let count) = hasFiveHour ? stats.remainingFiveHour : stats.remainingSevenDay {
                detail = String(localized: "\(detail) · ~\(count) tasks left", bundle: .module)
            }
            return .init(
                title: String(localized: "Switch to \(modelDisplayName(stats.model))", bundle: .module),
                detail: detail,
                action: .switchModel(stats.model)
            )
        }
        for alternative in alternatives where alternative.providerRaw != context.providerRaw {
            guard let altUsage = alternative.usage,
                  !altUsage.hasFiveHourLimit || altUsage.fiveHourPercent < alternativeFiveHourCeiling,
                  altUsage.sevenDayPercent < alternativeSevenDayCeiling
            else { continue }
            let altHasFiveHour = altUsage.hasFiveHourLimit
            var detail = altHasFiveHour
                ? String(
                    localized: "5-hour at \(formatPercent(altUsage.fiveHourPercent)), 7-day at \(formatPercent(altUsage.sevenDayPercent))",
                    bundle: .module
                )
                : String(localized: "7-day at \(formatPercent(altUsage.sevenDayPercent))", bundle: .module)
            let altEstimate = altHasFiveHour ? alternative.summary.remainingFiveHour : alternative.summary.remainingSevenDay
            if case .tasks(let count) = altEstimate {
                detail = String(localized: "\(detail) · ~\(count) tasks left", bundle: .module)
            }
            suggestions.append(.init(
                title: String(localized: "Switch to \(alternative.displayName)", bundle: .module),
                detail: detail,
                action: .switchProvider(alternative.providerRaw)
            ))
        }
        if hasFiveHour, !warnings.isEmpty, let reset = usage.fiveHourResetsAt, reset > now, usage.fiveHourPercent >= usage.sevenDayPercent {
            suggestions.append(.init(
                title: String(localized: "Wait for the 5-hour reset", bundle: .module),
                detail: String(localized: "Resets in \(formatInterval(reset.timeIntervalSince(now)))", bundle: .module),
                action: .waitForReset(reset)
            ))
        }

        return RateLimitAdvice(
            severity: warnings.isEmpty ? .info : .warning,
            reasons: reasons,
            suggestions: suggestions
        )
    }

    // MARK: - Rules

    enum LimitWindow {
        case fiveHour
        case sevenDay
    }

    /// Each window's sentences are spelled out in full so they translate as
    /// whole sentences rather than with the window name spliced in.
    static func nearLimitReason(
        _ window: LimitWindow,
        used: Double,
        estimate: RateLimitTaskCostSummary.Estimate,
        model: String
    ) -> String? {
        if case .tasks(let count) = estimate, count <= nearLimitTasks {
            switch (window, count) {
            case (.fiveHour, 0):
                return String(localized: "The 5-hour limit is nearly used up — another \(model) task will likely hit it.", bundle: .module)
            case (.sevenDay, 0):
                return String(localized: "The 7-day limit is nearly used up — another \(model) task will likely hit it.", bundle: .module)
            case (.fiveHour, 1):
                return String(localized: "Only about 1 more \(model) task fits in the 5-hour limit.", bundle: .module)
            case (.sevenDay, 1):
                return String(localized: "Only about 1 more \(model) task fits in the 7-day limit.", bundle: .module)
            case (.fiveHour, _):
                return String(localized: "Only about \(count) more \(model) tasks fit in the 5-hour limit.", bundle: .module)
            case (.sevenDay, _):
                return String(localized: "Only about \(count) more \(model) tasks fit in the 7-day limit.", bundle: .module)
            }
        }
        if used >= nearLimitPercent {
            switch window {
            case .fiveHour:
                return String(localized: "The 5-hour limit is \(formatPercent(used)) used.", bundle: .module)
            case .sevenDay:
                return String(localized: "The 7-day limit is \(formatPercent(used)) used.", bundle: .module)
            }
        }
        return nil
    }

    /// How long before `resetsAt` the limit runs out at the average rate so
    /// far in this window, or nil when it lasts (or there's too little data).
    static func exhaustionLead(used: Double, resetsAt: Date?, window: TimeInterval, now: Date) -> TimeInterval? {
        guard let resetsAt, resetsAt > now, used >= 20, used < 100 else { return nil }
        let elapsed = window - resetsAt.timeIntervalSince(now)
        // Too early in the window for the pace to mean much.
        guard elapsed >= window * 0.1 else { return nil }
        let ratePerSecond = used / elapsed
        let timeToFull = (100 - used) / ratePerSecond
        let lead = resetsAt.timeIntervalSince(now) - timeToFull
        // Ignore near-misses so the warning isn't noisy.
        return lead > window * 0.05 ? lead : nil
    }

    /// Models on the same provider that cost clearly less per task (or per
    /// token when per-task cost is unknown), cheapest first.
    static func cheaperModels(
        than current: RateLimitTaskCostSummary.ModelStats?,
        in summary: RateLimitTaskCostSummary
    ) -> [RateLimitTaskCostSummary.ModelStats] {
        guard let current else { return [] }
        return summary.models
            .filter { $0.model != current.model && $0.sampleCount >= 2 }
            .filter { candidate in
                if let mine = current.averageFiveHour, mine > 0, let theirs = candidate.averageFiveHour {
                    return theirs <= mine * cheaperRatio
                }
                if let mine = current.fiveHourPerMillionTokens, mine > 0, let theirs = candidate.fiveHourPerMillionTokens {
                    return theirs <= mine * cheaperRatio
                }
                return false
            }
            .sorted { ($0.averageFiveHour ?? .infinity) < ($1.averageFiveHour ?? .infinity) }
    }

    // MARK: - Formatting

    static func formatPercent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func formatPoints(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0...2)))
    }

    static func formatTokens(_ value: Double) -> String {
        Int(value).formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func formatInterval(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: max(60, seconds)) ?? ""
    }
}
