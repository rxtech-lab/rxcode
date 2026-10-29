import Foundation

/// Provider APIs supplement ACP, which does not expose account usage limits.
public enum ACPUsageProvider: String, CaseIterable, Sendable {
    case opencode, antigravity

    public var pluginID: String { "acp-\(rawValue)" }
    public var title: String { self == .opencode ? "OpenCode Go" : "Antigravity" }

    public static func provider(for client: ACPClientSpec) -> Self? {
        if let registry = client.registryId {
            switch registry.lowercased() {
            case "opencode": return .opencode
            case "antigravity", "antigravity-acp": return .antigravity
            default: return nil
            }
        }
        let command: String
        switch client.launch {
        case .binary(let path, _, _), .custom(let path, _, _):
            command = URL(fileURLWithPath: path).lastPathComponent
        case .npx, .uvx: return nil
        }
        switch command {
        case "opencode": return .opencode
        case "agy", "agy_acp_server", "antigravity-acp": return .antigravity
        default: return nil
        }
    }

    public func request(token: String) -> URLRequest {
        let endpoint = self == .opencode
            ? "https://opencode.ai/inference/go/v1/usage"
            : "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if self == .antigravity {
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("antigravity/acp", forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    public func metrics(from data: Data) throws -> [UsageMetric] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else {
            throw UsagePluginError.invalidResponse
        }
        let metrics: [UsageMetric]
        switch self {
        case .opencode:
            guard let usage = root["usage"] as? [String: Any] else { throw UsagePluginError.invalidResponse }
            metrics = [("rolling", "5-hour usage"), ("weekly", "Weekly usage"), ("monthly", "Monthly usage")].compactMap { id, title in
                guard let window = usage[id] as? [String: Any],
                      let percent = Self.number(window["percent"]), (0...100).contains(percent) else { return nil }
                return .init(id, title, value: percent, unit: "%", detail: Self.resetDetail(window["resetsAt"]))
            }
        case .antigravity:
            let payload = (root["response"] as? [String: Any]) ?? (root["summary"] as? [String: Any]) ?? root
            guard let groups = payload["groups"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
            metrics = groups.enumerated().flatMap { index, group -> [UsageMetric] in
                let title = group["displayName"] as? String ?? group["name"] as? String ?? "Quota"
                return (group["buckets"] as? [[String: Any]] ?? []).compactMap { bucket in
                    let remaining = bucket["remaining"] as? [String: Any]
                    let fraction = Self.number(bucket["remainingFraction"])
                        ?? Self.number(remaining?["remainingFraction"])
                        ?? (remaining?["case"] as? String == "remainingFraction" ? Self.number(remaining?["value"]) : nil)
                    guard bucket["disabled"] as? Bool != true,
                          let id = bucket["bucketId"] as? String ?? bucket["id"] as? String,
                          let fraction, (0...1).contains(fraction) else { return nil }
                    let name = bucket["displayName"] as? String ?? bucket["name"] as? String ?? id
                    return .init("\(index):\(id)", "\(title) · \(name)", value: (1 - fraction) * 100,
                                 unit: "%", detail: Self.resetDetail(bucket["resetTime"]))
                }
            }
        }
        guard !metrics.isEmpty else { throw UsagePluginError.invalidResponse }
        return metrics
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func resetDetail(_ value: Any?) -> String? {
        guard let text = value as? String,
              let date = ISO8601DateFormatter().date(from: text)
                ?? ISO8601DateFormatter.withFractionalSeconds.date(from: text) else { return nil }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private extension ISO8601DateFormatter {
    static var withFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

public enum ACPUsageFetchError: LocalizedError {
    case signIn(String), noAccess(String)
    public var errorDescription: String? {
        switch self {
        case .signIn(let title): "Open \(title) and sign in again to refresh usage."
        case .noAccess(let title): "\(title) denied usage access. Check your account and subscription."
        }
    }
}

public enum ACPUsageAPI {
    public static func fetch(provider: ACPUsageProvider, token: String, integration: UsageIntegration,
                             session: URLSession) async throws -> UsagePluginSnapshot {
        try await fetch(provider: provider, token: token, integration: integration, session: session, requestURL: nil)
    }

    /// Explicit URL injection is limited to native tests; synced configuration cannot redirect credentials.
    static func fetch(provider: ACPUsageProvider, token: String, integration: UsageIntegration,
                      session: URLSession, requestURL: URL?) async throws -> UsagePluginSnapshot {
        var request = provider.request(token: token)
        if let requestURL { request.url = requestURL }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
        if http.statusCode == 401 { throw ACPUsageFetchError.signIn(provider.title) }
        if http.statusCode == 403 { throw ACPUsageFetchError.noAccess(provider.title) }
        guard http.statusCode == 200 else { throw UsagePluginError.http(http.statusCode) }
        return .init(id: integration.id, pluginID: integration.pluginID, title: integration.title,
                     projectID: integration.projectID, scope: provider.title,
                     period: "Current account limits", metrics: try provider.metrics(from: data))
    }
}
