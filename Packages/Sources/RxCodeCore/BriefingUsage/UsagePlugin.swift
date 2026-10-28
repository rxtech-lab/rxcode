import Foundation

/// Versioned, credential-free contract shared by plugins, sync, and widgets.
public struct UsageMetric: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var value: Double?
    public var unit: String
    public var detail: String?
    public init(_ id: String, _ title: String, value: Double?, unit: String, detail: String? = nil) {
        self.id = id; self.title = title; self.value = value; self.unit = unit; self.detail = detail
    }
    public var formattedValue: String {
        guard let value, value.isFinite else { return "Unavailable" }
        if unit == "seconds" { return "\((value / 60).formatted(.number.precision(.fractionLength(1)))) min" }
        if unit == "%" { return "\(value.formatted(.number.precision(.fractionLength(1))))%" }
        return "\(value.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))) \(unit)"
    }
}

public struct UsagePluginSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var pluginID: String
    public var title: String
    public var projectID: UUID?
    public var scope: String
    public var period: String
    public var fetchedAt: Date
    public var metrics: [UsageMetric]
    public var error: String?
    public init(id: UUID, pluginID: String, title: String, projectID: UUID? = nil, scope: String,
                period: String, fetchedAt: Date = .now, metrics: [UsageMetric], error: String? = nil) {
        self.id = id; self.pluginID = pluginID; self.title = title; self.projectID = projectID
        self.scope = scope; self.period = period; self.fetchedAt = fetchedAt; self.metrics = metrics; self.error = error
    }
    public func isStale(at date: Date = .now) -> Bool { error != nil || date.timeIntervalSince(fetchedAt) > 3600 }
}

public struct UsageCardConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var integrationID: UUID
    /// Strings allow older clients to fall back when a new style arrives.
    public var style: String
    public var metricID: String?
    public var isVisible: Bool
    public var showInMenuBar: Bool
    public var showInWidget: Bool
    public init(id: UUID = UUID(), integrationID: UUID, style: String = "summary", metricID: String? = nil,
                isVisible: Bool = true, showInMenuBar: Bool = false, showInWidget: Bool = false) {
        self.id = id; self.integrationID = integrationID; self.style = style; self.metricID = metricID
        self.isVisible = isVisible; self.showInMenuBar = showInMenuBar; self.showInWidget = showInWidget
    }
    public static let styles = ["summary", "compact", "metrics"]
}

/// Configuration deliberately has no token or client-secret field.
public struct UsageOAuthConfiguration: Codable, Sendable, Equatable {
    public var clientID: String
    public var callbackURL: String
    public var scopes: String
    public init(clientID: String = "", callbackURL: String = "rxcode://usage-oauth", scopes: String = "") {
        self.clientID = clientID; self.callbackURL = callbackURL; self.scopes = scopes
    }
}

public struct UsageIntegration: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var pluginID: String
    public var title: String
    public var account: String
    public var resource: String
    public var oauth: UsageOAuthConfiguration?
    public var projectID: UUID?
    public init(id: UUID = UUID(), pluginID: String, title: String, account: String = "", resource: String = "", projectID: UUID? = nil) {
        self.id = id; self.pluginID = pluginID; self.title = title; self.account = account
        self.resource = resource; self.projectID = projectID
    }
}

public struct UsageDashboard: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var integrations: [UsageIntegration]
    public var cards: [UsageCardConfiguration]
    public var snapshots: [UsagePluginSnapshot]
    public init(integrations: [UsageIntegration] = [], cards: [UsageCardConfiguration] = [], snapshots: [UsagePluginSnapshot] = []) {
        self.integrations = integrations; self.cards = cards; self.snapshots = snapshots
    }
    public func snapshot(for card: UsageCardConfiguration) -> UsagePluginSnapshot? {
        snapshots.first { $0.id == card.integrationID }
    }
}

public struct UsagePluginDescriptor: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let authentication: String
    public let resourceLabel: String
    public init(id: String, title: String, authentication: String, resourceLabel: String) {
        self.id = id; self.title = title; self.authentication = authentication; self.resourceLabel = resourceLabel
    }
}

/// Native plugin implementations are registered by stable ID. Credentials are
/// supplied at fetch time and must never be included in returned snapshots.
public protocol UsagePlugin: Sendable {
    var descriptor: UsagePluginDescriptor { get }
    func fetch(configuration: UsageIntegration, credential: String, now: Date) async throws -> UsagePluginSnapshot
}

public enum UsagePluginError: LocalizedError {
    case invalidConfiguration, invalidResponse, http(Int), paginationLimit
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Complete the integration account and resource settings."
        case .invalidResponse: "The provider returned an unsupported usage response."
        case .http(let code): "Usage request failed (HTTP \(code)). Check credentials, permissions, and plan eligibility."
        case .paginationLimit: "The provider returned too many pages. Narrow the integration scope."
        }
    }
}
