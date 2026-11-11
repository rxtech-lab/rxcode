import Foundation

/// Read-only MCP query over configured connections, independent of card visibility.
public struct IntegrationUsageQuery: Sendable {
    public let pluginID: String?
    public let integrationID: UUID?
    public let refresh: Bool

    public init(arguments: JSONValue) throws {
        if let value = arguments["plugin_id"] {
            guard let id = value.stringValue, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IDEToolError.invalidArguments("plugin_id must be a nonempty string.")
            }
            pluginID = id
        } else { pluginID = nil }
        if let value = arguments["integration_id"] {
            guard let raw = value.stringValue, let id = UUID(uuidString: raw) else {
                throw IDEToolError.invalidArguments("integration_id must be a valid UUID.")
            }
            integrationID = id
        } else { integrationID = nil }
        if let value = arguments["refresh"] {
            guard let flag = value.boolValue else { throw IDEToolError.invalidArguments("refresh must be a boolean.") }
            refresh = flag
        } else { refresh = false }
    }

    public func integrations(in dashboard: UsageDashboard) -> [UsageIntegration] {
        dashboard.integrations.filter {
            (pluginID == nil || $0.pluginID == pluginID) && (integrationID == nil || $0.id == integrationID)
        }
    }

    public func report(from dashboard: UsageDashboard, now: Date = .now) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        let entries: [JSONValue] = integrations(in: dashboard).map { integration in
            let snapshot = dashboard.snapshots.first { $0.id == integration.id }
            // Failed first fetches have no observation time and must not appear fresh.
            let fetchedAt = snapshot.flatMap { $0.fetchedAt == .distantPast ? nil : $0.fetchedAt }
            return .object([
                "integration_id": .string(integration.id.uuidString),
                "plugin_id": .string(integration.pluginID),
                "title": .string(integration.title),
                "account": .string(integration.account),
                "resource": .string(integration.resource),
                "project_id": integration.projectID.map { .string($0.uuidString) } ?? .null,
                "available": .bool(snapshot != nil && fetchedAt != nil),
                "stale": .bool(snapshot?.isStale(at: now) ?? true),
                "scope": snapshot.map { .string($0.scope) } ?? .null,
                "period": snapshot.map { .string($0.period) } ?? .null,
                "fetched_at": fetchedAt.map { .string(formatter.string(from: $0)) } ?? .null,
                "error": snapshot?.error.map(JSONValue.string) ?? .null,
                "metrics": .array((snapshot?.metrics ?? []).map { metric in
                    .object([
                        "id": .string(metric.id), "title": .string(metric.title),
                        "value": metric.value.flatMap { $0.isFinite ? .number($0) : nil } ?? .null,
                        "unit": .string(metric.unit), "detail": metric.detail.map(JSONValue.string) ?? .null
                    ])
                })
            ])
        }
        return .object(["integrations": .array(entries)])
    }
}
