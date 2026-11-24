import Foundation
import RxCodeExtensionSDK

enum CloudflareUsage {
    static let base = URL(string: "https://api.cloudflare.com/client/v4")!

    static func fetch(_ integration: ExtensionUsageIntegration, host: RxCodeHost, now: Date) async throws -> ExtensionUsageSnapshot {
        let account = try await ExtensionUsageAccount.selected(for: integration, host: host)
        guard !account.isEmpty else { throw ExtensionCallError.invalidRequest }
        let metrics: [UsageMetric]
        let period: String
        switch CloudflareUsageScope(resource: integration.resource) {
        case .account:
            let url = base.appending(component: "accounts").appending(component: try component(account)).appending(component: "billable-usage")
            let (response, slot) = try await request(URLRequest(url: url), host: host, slots: ["billing", "oauth", "primary"])
            if response.status == 401 && slot == "billing" {
                throw ExtensionUsageFailure("Cloudflare rejected the billing API token. Replace it in the integration sheet.")
            }
            if response.status == 403 {
                let message = slot == "billing"
                    ? "Cloudflare denied the billing API token access to account billing usage. Check that the token includes Account > Billing > Read for this account."
                    : "Cloudflare denied access to account billing usage. Cloudflare sign-in cannot grant Billing Read. Add a Cloudflare API token with Account > Billing > Read or use Worker script or R2 bucket analytics."
                throw ExtensionUsageFailure(message)
            }
            metrics = try UsageResponseParser.cloudflare(checkedBody(response))
            period = "Current billing period"
        case .zone:
            let dates = ISO8601DateFormatter()
            let url = base.appending(component: "zones").appending(component: try component(integration.resource))
                .appending(path: "analytics/dashboard").appending(queryItems: [
                    .init(name: "since", value: dates.string(from: now.addingTimeInterval(-30 * 86400))),
                    .init(name: "until", value: dates.string(from: now))
                ])
            let (response, _) = try await request(URLRequest(url: url), host: host)
            metrics = try UsageResponseParser.cloudflareZone(checkedBody(response))
            period = "Last 30 days"
        case .worker, .r2:
            let query = try CloudflareResourceUsage.request(account: account, resource: integration.resource, now: now)
            let (response, _) = try await request(query, host: host)
            metrics = try CloudflareResourceUsage.metrics(checkedBody(response), resource: integration.resource)
            period = "Last 24 hours · analytics"
        }
        let scope = integration.resource.isEmpty ? account : "\(account) / \(integration.resource)"
        return .init(integration: integration, scope: scope, period: period, fetchedAt: now, metrics: metrics)
    }

    static func request(_ request: URLRequest, host: RxCodeHost, slots: [String] = ["oauth", "primary"]) async throws -> (ExtensionHTTPResponse, String) {
        guard let url = request.url else { throw ExtensionCallError.invalidRequest }
        for slot in slots {
            do {
                return (try await host.fetch(url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:],
                                             body: request.httpBody, credentialSlot: slot), slot)
            } catch ExtensionCallError.credentialUnavailable {
                continue
            }
        }
        throw ExtensionCallError.credentialUnavailable
    }

    static func checkedBody(_ response: ExtensionHTTPResponse) throws -> Data {
        guard (200..<300).contains(response.status) else {
            let message = UsageResponseParser.errorMessage(response.body) ?? "Check credentials, permissions, and plan eligibility."
            throw ExtensionUsageFailure("Usage request failed (HTTP \(response.status)): \(message)")
        }
        return response.body
    }

    private static func component(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..",
              value.allSatisfy({ $0.isLetter || $0.isNumber || "-_ .".contains($0) }) else {
            throw ExtensionCallError.invalidRequest
        }
        return value
    }
}
