import Foundation
import Observation

/// Rate limit usage data passed through ChatBridge to avoid direct RateLimitService dependency in RxCodeChatKit.
///
/// `Codable` so it can travel over the mobile sync protocol inside a snapshot.
public struct RateLimitUsage: Sendable, Codable, Equatable {
    public let fiveHourPercent: Double
    public let sevenDayPercent: Double
    public let twentyFourHourPercent: Double?
    public let fiveHourResetsAt: Date?
    public let sevenDayResetsAt: Date?
    public let twentyFourHourResetsAt: Date?

    public init(
        fiveHourPercent: Double,
        sevenDayPercent: Double,
        twentyFourHourPercent: Double? = nil,
        fiveHourResetsAt: Date?,
        sevenDayResetsAt: Date?,
        twentyFourHourResetsAt: Date? = nil
    ) {
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
        self.twentyFourHourPercent = twentyFourHourPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
        self.twentyFourHourResetsAt = twentyFourHourResetsAt
    }

    /// False when the plan has no separate 5-hour limit. Such plans report a
    /// single window, which shows up as identical 5-hour and 7-day readings
    /// that reset at the same time.
    public var hasFiveHourLimit: Bool {
        guard fiveHourPercent == sevenDayPercent,
              let fiveHourResetsAt, let sevenDayResetsAt
        else { return true }
        return abs(fiveHourResetsAt.timeIntervalSince(sevenDayResetsAt)) > 60
    }

    /// Compact percentage shown in the menu bar and chat status line.
    public static func formattedPercent(_ value: Double) -> String {
        let decimals = value > 0 && value < 1 ? 1 : 0
        return (value / 100).formatted(
            .percent.precision(.fractionLength(decimals)).rounded(rule: .toNearestOrAwayFromZero)
        )
    }
}

/// The latest account limits for the local CLI providers, shared by all workspace windows.
@MainActor
@Observable
public final class AccountRateLimits {
    public struct Reading: Sendable {
        public let usage: RateLimitUsage
        public let measuredAt: Date
    }

    private var readings: [AgentProvider: Reading] = [:]
    @ObservationIgnored private var refreshes: [AgentProvider: Task<RateLimitUsage?, Never>] = [:]

    public init() {}

    public subscript(provider: AgentProvider) -> Reading? { readings[provider] }

    /// Concurrent refreshes of the same account share a request. A failed fetch leaves its last reading available.
    public func refresh(
        for provider: AgentProvider,
        fetch: @escaping @MainActor () async -> RateLimitUsage?
    ) async -> RateLimitUsage? {
        if let pending = refreshes[provider] { return await pending.value }
        let task = Task<RateLimitUsage?, Never> {
            defer { refreshes[provider] = nil }
            guard let usage = await fetch() else { return nil }
            readings[provider] = Reading(usage: usage, measuredAt: .now)
            return usage
        }
        refreshes[provider] = task
        return await task.value
    }
}
