import Foundation

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
}
