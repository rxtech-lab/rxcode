import Foundation
import RxCodeExtensionSDK

enum TursoUsage {
    static func fetch(_ integration: ExtensionUsageIntegration, host: RxCodeHost, now: Date) async throws -> ExtensionUsageSnapshot {
        let account = try component(integration.account)
        let scoped = !integration.resource.isEmpty
        var endpoint = URL(string: "https://api.turso.tech/v1/organizations")!.appending(component: account)
        if scoped {
            let dates = ISO8601DateFormatter()
            endpoint = endpoint.appending(component: "databases").appending(component: try component(integration.resource))
                .appending(component: "usage").appending(queryItems: [
                    .init(name: "from", value: dates.string(from: now.addingTimeInterval(-30 * 86400))),
                    .init(name: "to", value: dates.string(from: now))
                ])
        } else {
            endpoint = endpoint.appending(component: "usage")
        }
        let response = try await host.fetch(endpoint, credentialSlot: "primary")
        guard (200..<300).contains(response.status) else { throw ExtensionCallError.invalidRequest }
        return try .init(integration: integration, scope: scoped ? "\(account) / \(integration.resource)" : account,
                         period: scoped ? "Last 30 days" : "Current billing period", fetchedAt: now,
                         metrics: UsageResponseParser.turso(response.body, database: scoped))
    }

    private static func component(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..",
              value.allSatisfy({ $0.isLetter || $0.isNumber || "-_ .".contains($0) }) else {
            throw ExtensionCallError.invalidRequest
        }
        return value
    }
}
