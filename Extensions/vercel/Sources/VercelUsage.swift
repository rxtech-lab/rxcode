import Foundation
import RxCodeExtensionSDK

enum VercelUsage {
    static func fetch(_ integration: ExtensionUsageIntegration, host: RxCodeHost, now: Date) async throws -> ExtensionUsageSnapshot {
        let base = URL(string: "https://api.vercel.com")!
        // Vercel's OAuth scopes currently exclude billing. Always use the saved access token.
        let configured = try await ExtensionUsageAccount.selected(for: integration, host: host)
        var team = configured
        if team.isEmpty {
            let response = try await host.fetch(base.appending(path: "v2/user"), credentialSlot: "primary")
            team = try UsageResponseParser.vercelDefaultTeam(checkedBody(response)) ?? ""
        }
        let dates = ISO8601DateFormatter()
        var query = VercelAccounts.scope(team).map { URLQueryItem(name: $0.key, value: $0.value) }
        query.append(.init(name: "from", value: dates.string(from: now.addingTimeInterval(-30 * 86400))))
        query.append(.init(name: "to", value: dates.string(from: now)))
        let charges = try await host.fetch(base.appending(path: "v1/billing/charges").appending(queryItems: query), credentialSlot: "primary")
        var metrics = try UsageResponseParser.vercel(checkedBody(charges), project: integration.resource)
        let credits = try await gatewayCredits(host: host)
        metrics.insert(credits, at: metrics.firstIndex { !$0.id.hasPrefix("billable|") } ?? metrics.endIndex)
        let account = configured.isEmpty ? "Default team" : configured
        let scope = integration.resource.isEmpty ? account : "\(account) / \(integration.resource)"
        return .init(integration: integration, scope: scope, period: "Last 30 days", fetchedAt: now, metrics: metrics)
    }

    static func checkedBody(_ response: ExtensionHTTPResponse) throws -> Data {
        guard (200..<300).contains(response.status) else {
            let message = UsageResponseParser.errorMessage(response.body) ?? "Check the access token and its team scope."
            throw ExtensionUsageFailure("Usage request failed (HTTP \(response.status)): \(message)")
        }
        return response.body
    }

    private static func gatewayCredits(host: RxCodeHost) async throws -> UsageMetric {
        let detail: String
        do {
            let response = try await host.fetch(URL(string: "https://ai-gateway.vercel.sh/v1/credits")!, credentialSlot: "gateway")
            if (200..<300).contains(response.status),
               let metric = try? UsageResponseParser.vercelGatewayCredits(response.body) { return metric }
            detail = "Could not refresh AI Gateway credits. Check the team's AI Gateway API key."
        } catch ExtensionCallError.credentialUnavailable {
            detail = "Add an AI Gateway API key for this team in the integration sheet."
        } catch ExtensionCallError.timeout {
            detail = "Could not refresh AI Gateway credits. Check the team's AI Gateway API key."
        }
        return .init(id: "ai-gateway-balance", title: "AI Gateway credits", value: nil, unit: "USD", detail: detail)
    }
}
