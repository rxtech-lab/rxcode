import Foundation
import RxCodeExtensionSDK

enum NeonUsage {
    static func fetch(_ integration: ExtensionUsageIntegration, host: RxCodeHost, now: Date) async throws -> ExtensionUsageSnapshot {
        guard !integration.account.isEmpty else { throw ExtensionCallError.invalidRequest }
        let dates = ISO8601DateFormatter()
        var query = [
            URLQueryItem(name: "org_id", value: integration.account),
            URLQueryItem(name: "from", value: dates.string(from: now.addingTimeInterval(-30 * 86400))),
            URLQueryItem(name: "to", value: dates.string(from: now)),
            URLQueryItem(name: "granularity", value: "daily"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "metrics", value: "compute_unit_seconds,root_branch_bytes_month,public_network_transfer_bytes")
        ]
        if !integration.resource.isEmpty { query.append(.init(name: "project_ids", value: integration.resource)) }
        let endpoint = URL(string: "https://console.neon.tech/api/v2/consumption_history/v2/projects")!
        var cursor: String?
        var seen = Set<String>()
        var totals: [String: Double] = [:]
        repeat {
            try Task.checkCancellation()
            let pageQuery = query + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let response = try await host.fetch(endpoint.appending(queryItems: pageQuery), credentialSlot: "primary")
            guard (200..<300).contains(response.status) else { throw ExtensionCallError.invalidRequest }
            let page = try UsageResponseParser.neon(response.body)
            for (key, value) in page.totals { totals[key, default: 0] += value }
            cursor = page.cursor
            if let cursor, !seen.insert(cursor).inserted || seen.count > 100 { throw ExtensionCallError.invalidRequest }
        } while cursor != nil
        let units = ["compute_unit_seconds": "CU seconds", "root_branch_bytes_month": "byte-hours", "public_network_transfer_bytes": "bytes"]
        let metrics = try totals.sorted { $0.key < $1.key }.map { key, value in
            guard let unit = units[key], value.isFinite else { throw ExtensionCallError.invalidRequest }
            return UsageMetric(id: key, title: key.replacingOccurrences(of: "_", with: " "), value: value, unit: unit)
        }
        let scope = integration.resource.isEmpty ? integration.account : "\(integration.account) / \(integration.resource)"
        return .init(integration: integration, scope: scope, period: "Last 30 days · daily granularity", fetchedAt: now, metrics: metrics)
    }
}
