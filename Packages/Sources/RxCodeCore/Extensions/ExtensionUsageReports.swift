import Foundation

public struct LocalUsageSummaryDTO: Codable, Sendable {
    public let range: String
    public let summary: UsageStatsSummary

    public let modelLabels: [String: String]
    public let providerLabels: [String: String]

    public init(range: UsageStatsRange, summary: UsageStatsSummary, modelLabels: [String: String] = [:],
                providerLabels: [String: String] = [:]) {
        self.modelLabels = modelLabels
        self.providerLabels = providerLabels
        self.range = range.rawValue
        self.summary = summary
    }
}

public struct RateLimitReportDTO: Codable, Sendable {
    public let provider: String
    public let range: String
    public let providerLabel: String
    public let measuredAt: Date?
    public let hasFiveHourLimit: Bool
    public let current: RateLimitUsage?
    public let history: [RateLimitSamplePoint]
    public let costs: RateLimitTaskCostSummary

    public init(provider: AgentProvider, range: UsageStatsRange, current: RateLimitUsage?,
                history: [RateLimitSamplePoint], costs: RateLimitTaskCostSummary, measuredAt: Date? = nil) {
        self.providerLabel = provider.displayNameText
        self.measuredAt = measuredAt
        self.hasFiveHourLimit = current?.hasFiveHourLimit == true
        self.provider = provider.rawValue
        self.range = range.rawValue
        self.current = current
        self.history = history
        self.costs = costs
    }
}
