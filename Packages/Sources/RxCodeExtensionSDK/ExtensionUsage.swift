import Foundation

/// Credential-free configuration passed by the host. This shape decodes existing dashboard integrations.
public struct ExtensionUsageIntegration: Codable, Equatable, Sendable {
    public struct OAuth: Codable, Equatable, Sendable {
        public let clientID: String
        public let callbackURL: String
        public let scopes: String
    }
    public let id: UUID
    public let pluginID: String
    public let title: String
    public let account: String
    public let resource: String
    public let projectID: UUID?
    public let oauth: OAuth?
}

/// Native provider output uses the same IDs and timestamp encoding as mobile and widget snapshots.
public struct ExtensionUsageSnapshot: Codable, Equatable, Sendable {
    public struct Metric: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let value: Double?
        public let unit: String
        public let detail: String?
        public let resetsAt: Date?

        public init(id: String, title: String, value: Double?, unit: String, detail: String? = nil, resetsAt: Date? = nil) {
            self.id = id
            self.title = title
            self.value = value
            self.unit = unit
            self.detail = detail
            self.resetsAt = resetsAt
        }
    }
    public let id: UUID
    public let pluginID: String
    public let title: String
    public let projectID: UUID?
    public let scope: String
    public let period: String
    public let fetchedAt: Date
    public let metrics: [Metric]
    public let error: String?

    public init(integration: ExtensionUsageIntegration, scope: String, period: String,
                fetchedAt: Date = .now, metrics: [Metric], error: String? = nil) {
        id = integration.id
        pluginID = integration.pluginID
        title = integration.title
        projectID = integration.projectID
        self.scope = scope
        self.period = period
        self.fetchedAt = fetchedAt
        self.metrics = metrics
        self.error = error
    }
}
