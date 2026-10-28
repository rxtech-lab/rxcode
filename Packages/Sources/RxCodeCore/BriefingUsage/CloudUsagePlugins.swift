import Foundation
import CoreFoundation


/// Network work is isolated from UI actors. Each provider owns its response
/// interpretation; only normalized metrics cross the plugin boundary.
public actor CloudUsagePlugin: UsagePlugin {
    public nonisolated let descriptor: UsagePluginDescriptor
    private let session: URLSession
    private let cloudflareAnalyticsEndpoint: URL
    public init(id: String, session: URLSession = .shared,
                cloudflareAnalyticsEndpoint: URL = URL(string: "https://api.cloudflare.com/client/v4/graphql")!) {
        self.session = session
        self.cloudflareAnalyticsEndpoint = cloudflareAnalyticsEndpoint
        let names = ["vercel": "Vercel", "neon": "Neon", "turso": "Turso", "cloudflare": "Cloudflare", "github-ci": "GitHub CI"]
        descriptor = .init(id: id, title: names[id] ?? id,
                           authentication: ["vercel", "cloudflare"].contains(id) ? "OAuth" : "API key",
                           resourceLabel: id == "turso" ? "Database name (optional)" : "Project / resource ID (optional)")
    }
    public func fetch(configuration c: UsageIntegration, credential: String, now: Date) async throws -> UsagePluginSnapshot {
        guard !credential.isEmpty, !c.account.isEmpty else { throw UsagePluginError.invalidConfiguration }
        let to = ISO8601DateFormatter().string(from: now)
        let from = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 86400))
        var metrics: [UsageMetric]
        var period = "Last 30 days"
        switch descriptor.id {
        case "vercel":
            let data = try await request("https://api.vercel.com/v1/billing/charges", query: ["teamId": c.account, "from": from, "to": to], token: credential)
            metrics = try UsageResponseParser.vercel(data, project: c.resource)
        case "turso":
            let base = "https://api.turso.tech/v1/organizations/\(try component(c.account))"
            let path = c.resource.isEmpty ? "/usage" : "/databases/\(try component(c.resource))/usage"
            let data = try await request(base + path, query: c.resource.isEmpty ? [:] : ["from": from, "to": to], token: credential)
            metrics = try UsageResponseParser.turso(data, database: !c.resource.isEmpty)
            if c.resource.isEmpty { period = "Current billing period" }
        case "neon":
            var totals: [String: Double] = [:]
            var cursor: String?
            var seen = Set<String>()
            repeat {
                var query = ["org_id": c.account, "from": from, "to": to, "granularity": "daily", "limit": "100",
                             "metrics": "compute_unit_seconds,root_branch_bytes_month,public_network_transfer_bytes"]
                if !c.resource.isEmpty { query["project_ids"] = c.resource }
                query["cursor"] = cursor
                let data = try await request("https://console.neon.tech/api/v2/consumption_history/v2/projects", query: query, token: credential)
                let page = try UsageResponseParser.neon(data)
                for (key, value) in page.totals { totals[key, default: 0] += value }
                cursor = page.cursor
                if let cursor, (!seen.insert(cursor).inserted || seen.count > 100) { throw UsagePluginError.paginationLimit }
            } while cursor != nil
            metrics = totals.sorted { $0.key < $1.key }.map { .init($0.key, $0.key.replacingOccurrences(of: "_", with: " "), value: $0.value, unit: $0.key == "compute_unit_seconds" ? "CU seconds" : ($0.key == "root_branch_bytes_month" ? "byte-hours" : "bytes")) }
            period = "Last 30 days · daily granularity"
        case "cloudflare":
            let scope = CloudflareUsageScope(resource: c.resource)
            if scope == .worker || scope == .r2 {
                var request = try CloudflareResourceUsage.request(account: c.account, resource: c.resource,
                    now: now, endpoint: cloudflareAnalyticsEndpoint)
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                let data = try await send(request)
                metrics = try CloudflareResourceUsage.metrics(data, resource: c.resource)
                period = "Last 24 hours · analytics"
            } else if c.resource.isEmpty {
                let data = try await request("https://api.cloudflare.com/client/v4/accounts/\(try component(c.account))/billing/usage",
                    query: ["since": from, "until": to, "time_delta": "day", "limit": "1000"], token: credential)
                metrics = try UsageResponseParser.cloudflare(data)
            } else {
                let data = try await request("https://api.cloudflare.com/client/v4/zones/\(try component(c.resource))/analytics/dashboard",
                    query: ["since": from, "until": to], token: credential)
                metrics = try UsageResponseParser.cloudflareZone(data)
            }
        default: throw UsagePluginError.invalidConfiguration
        }
        return .init(id: c.id, pluginID: c.pluginID, title: c.title, projectID: c.projectID,
                     scope: c.resource.isEmpty ? c.account : "\(c.account) / \(c.resource)", period: period, fetchedAt: now, metrics: metrics)
    }
    private func component(_ value: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "-_ .".contains($0) }),
              let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw UsagePluginError.invalidConfiguration }
        return encoded
    }
    private func request(_ base: String, query: [String: String], token: String) async throws -> Data {
        var url = URLComponents(string: base)!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw UsagePluginError.http(http.statusCode) }
        guard data.count <= 32 * 1024 * 1024 else { throw UsagePluginError.invalidResponse }
        return data
    }
}

public enum UsageResponseParser {
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsagePluginError.invalidResponse }
        return object
    }
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = value as? String, let value = Double(text), value.isFinite { return value }
        return nil
    }
    public static func vercel(_ data: Data, project: String) throws -> [UsageMetric] {
        guard let text = String(data: data, encoding: .utf8) else { throw UsagePluginError.invalidResponse }
        var totals: [String: Double] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let row = try object(Data(line.utf8))
            guard let amount = number(row["BilledCost"]), let currency = row["BillingCurrency"] as? String,
                  let service = row["ServiceName"] as? String else { throw UsagePluginError.invalidResponse }
            if !project.isEmpty {
                let tags = row["Tags"] as? [String: Any]
                guard tags?["ProjectId"] as? String == project else { continue }
            }
            totals["\(currency)|\(service)", default: 0] += amount
        }
        return totals.sorted { $0.key < $1.key }.map {
            let parts = $0.key.split(separator: "|", maxSplits: 1)
            return .init($0.key, String(parts[1]), value: $0.value, unit: String(parts[0]))
        }
    }
    public static func turso(_ data: Data, database: Bool) throws -> [UsageMetric] {
        let root = try object(data)
        let entity = root[database ? "database" : "organization"] as? [String: Any]
        guard let usage = entity?[database ? "total" : "usage"] as? [String: Any] else { throw UsagePluginError.invalidResponse }
        return try ["rows_read", "rows_written", "storage_bytes", "bytes_synced"].map { key in
            guard let value = number(usage[key]) else { throw UsagePluginError.invalidResponse }
            return .init(key, key.replacingOccurrences(of: "_", with: " "), value: value, unit: key.contains("bytes") ? "bytes" : "rows")
        }
    }
    public static func neon(_ data: Data) throws -> (totals: [String: Double], cursor: String?) {
        let root = try object(data)
        guard let projects = root["projects"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
        var totals: [String: Double] = [:]
        for project in projects {
            guard let periods = project["periods"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
            for period in periods {
                guard let consumption = period["consumption"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
                for window in consumption {
                    guard let metrics = window["metrics"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
                    for metric in metrics {
                        guard let key = metric["metric_name"] as? String, let value = number(metric["value"]) else { throw UsagePluginError.invalidResponse }
                        if ["compute_unit_seconds", "root_branch_bytes_month", "public_network_transfer_bytes"].contains(key) {
                            totals[key, default: 0] += value
                        }
                    }
                }
            }
        }
        let cursor = (root["pagination"] as? [String: Any])?["cursor"] as? String
        return (totals, cursor.flatMap { $0.isEmpty ? nil : $0 })
    }
    public static func cloudflare(_ data: Data) throws -> [UsageMetric] {
        let root = try object(data)
        guard root["success"] as? Bool == true, let rows = root["result"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
        let units = ["workersRequests": "requests", "workersKVReads": "reads", "streamMinutesViewed": "minutes", "argoAcceleratedBytes": "bytes", "imageResizingRequests": "requests", "spectrumBytesTransferred": "bytes", "loadBalancingQueries": "queries", "mediaUniqueTransformations": "transformations", "rateLimitingRequestsAllowed": "requests"]
        return units.keys.sorted().compactMap { key in
            let values = rows.compactMap { number($0[key]) }
            guard !values.isEmpty else { return nil }
            return .init(key, key, value: values.reduce(0, +), unit: units[key]!)
        }
    }
    public static func cloudflareZone(_ data: Data) throws -> [UsageMetric] {
        let root = try object(data)
        guard root["success"] as? Bool == true, let result = root["result"] as? [String: Any],
              let totals = result["totals"] as? [String: Any] else { throw UsagePluginError.invalidResponse }
        return try ["requests", "bandwidth"].map { key in
            guard let item = totals[key] as? [String: Any], let value = number(item["all"]) else { throw UsagePluginError.invalidResponse }
            return .init(key, key.capitalized, value: value, unit: key == "bandwidth" ? "bytes" : "requests")
        }
    }
}
