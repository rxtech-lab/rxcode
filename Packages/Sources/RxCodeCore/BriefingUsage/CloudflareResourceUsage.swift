import Foundation

/// Resource selectors preserve existing empty-account and bare-zone settings.
public enum CloudflareUsageScope: String, CaseIterable, Sendable {
    case account, zone, worker, r2

    public init(resource: String) {
        if resource.isEmpty { self = .account }
        else if resource.hasPrefix("worker:") { self = .worker }
        else if resource.hasPrefix("r2:") { self = .r2 }
        else { self = .zone }
    }

    public var title: String {
        switch self {
        case .account: "Account consumption"
        case .zone: "Zone traffic"
        case .worker: "Worker script"
        case .r2: "R2 bucket"
        }
    }

    public func resource(named name: String) -> String {
        switch self {
        case .account: ""
        case .zone: name
        case .worker, .r2: "\(rawValue):\(name)"
        }
    }

    public func name(in resource: String) -> String {
        self == .worker || self == .r2 ? String(resource.dropFirst(rawValue.count + 1)) : resource
    }
}

/// Analytics are usage observations, not an invoice or estimated dollar cost.
public enum CloudflareResourceUsage {
    public static func request(account: String, resource: String, now: Date,
                               endpoint: URL = URL(string: "https://api.cloudflare.com/client/v4/graphql")!) throws -> URLRequest {
        let scope = CloudflareUsageScope(resource: resource)
        let name = scope.name(in: resource)
        guard [.worker, .r2].contains(scope), !account.isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsagePluginError.invalidConfiguration
        }
        let field = scope == .worker ? "scriptName" : "bucketName"
        let filter = "datetime_geq: $start, datetime_leq: $end, \(field): $resource"
        let nodes: String
        if scope == .worker {
            nodes = "activity: workersInvocationsAdaptive(limit: 1, filter: { \(filter) }) { sum { requests errors } }"
        } else {
            nodes = """
            activity: r2OperationsAdaptiveGroups(limit: 1, filter: { \(filter) }) { sum { requests } }
            storage: r2StorageAdaptiveGroups(limit: 1, filter: { \(filter) }, orderBy: [datetime_DESC]) {
                max { objectCount payloadSize metadataSize } dimensions { datetime }
            }
            """
        }
        let query = """
        query ResourceUsage($account: string!, $resource: string!, $start: Time!, $end: Time!) {
            viewer { accounts(filter: { accountTag: $account }) { \(nodes) } }
        }
        """
        let formatter = ISO8601DateFormatter()
        // A bounded daily window also works for plans with shorter retention.
        let variables = ["account": account, "resource": name,
                         "start": formatter.string(from: now.addingTimeInterval(-86400)),
                         "end": formatter.string(from: now)]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        return request
    }

    public static func metrics(_ data: Data, resource: String) throws -> [UsageMetric] {
        let scope = CloudflareUsageScope(resource: resource)
        guard [.worker, .r2].contains(scope) else { throw UsagePluginError.invalidConfiguration }
        let response = try JSONDecoder().decode(Response.self, from: data)
        // Reject partial GraphQL results rather than publishing understated totals.
        guard response.errors?.isEmpty != false,
              let accounts = response.data?.viewer.accounts, accounts.count == 1,
              let account = accounts.first, account.activity.count <= 1 else {
            throw UsagePluginError.invalidResponse
        }
        func value(_ row: [String: Double]?, _ key: String) throws -> Double? {
            guard let row else { return nil }
            guard let number = row[key], number.isFinite, number >= 0 else { throw UsagePluginError.invalidResponse }
            return number
        }
        let sum = account.activity.first?.sum
        if !account.activity.isEmpty && sum == nil { throw UsagePluginError.invalidResponse }
        let detail = "Analytics · last 24 hours · not billed cost"
        var metrics: [UsageMetric] = [
            .init("requests", scope == .worker ? "Worker requests" : "R2 operations",
                  value: try value(sum, "requests"), unit: "requests", detail: detail)
        ]
        if scope == .worker {
            metrics.append(.init("errors", "Worker errors", value: try value(sum, "errors"), unit: "errors"))
        } else {
            guard let storage = account.storage, storage.count <= 1 else { throw UsagePluginError.invalidResponse }
            let latest = storage.first
            if let latest, latest.max == nil || latest.dimensions?.datetime == nil { throw UsagePluginError.invalidResponse }
            let timestamp = latest?.dimensions?.datetime.map { "Latest sample: \($0)" } ?? "No storage sample in last 24 hours"
            for (key, title, unit) in [("payloadSize", "Stored object data", "bytes"),
                                        ("metadataSize", "Stored metadata", "bytes"), ("objectCount", "Objects", "objects")] {
                metrics.append(.init(key, title, value: try value(latest?.max, key), unit: unit, detail: timestamp))
            }
        }
        return metrics
    }

    private struct Response: Decodable {
        let data: DataBody?
        let errors: [GraphQLError]?
    }
    private struct GraphQLError: Decodable {}
    private struct DataBody: Decodable { let viewer: Viewer }
    private struct Viewer: Decodable { let accounts: [Account] }
    private struct Account: Decodable { let activity: [Row]; let storage: [Row]? }
    private struct Row: Decodable {
        let sum: [String: Double]?
        let max: [String: Double]?
        let dimensions: Dimensions?
    }
    private struct Dimensions: Decodable { let datetime: String? }
}
