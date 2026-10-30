import Foundation

/// Limits observed while a particular model was selected. Provider limits are
/// shared account quotas, not measurements of that model's individual consumption.
public struct CodingUsageLimitSnapshot: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case start, result, end }
    public enum Status: String, Codable, Sendable { case available, stale, unavailable, unsupported }

    public var phase: Phase
    public var capturedAt: Date
    public var measuredAt: Date?
    public var provider: String
    public var acpClientID: String?
    public var model: String?
    public var status: Status
    public var scope: String
    public var source: String
    public var rateLimits: RateLimitUsage?
    public var hasFiveHourLimit: Bool?
    public var metrics: [UsageMetric]
    public var reason: String?

    public init(phase: Phase, provider: String, acpClientID: String? = nil, model: String?,
                status: Status, scope: String, source: String, measuredAt: Date? = nil,
                rateLimits: RateLimitUsage? = nil, metrics: [UsageMetric] = [],
                reason: String? = nil, capturedAt: Date = .now) {
        self.phase = phase
        self.capturedAt = capturedAt
        self.measuredAt = measuredAt
        self.provider = provider
        self.acpClientID = acpClientID
        self.model = model
        self.status = status
        self.scope = scope
        self.source = source
        self.rateLimits = rateLimits
        self.hasFiveHourLimit = rateLimits?.hasFiveHourLimit
        self.metrics = metrics
        self.reason = reason
    }
}
