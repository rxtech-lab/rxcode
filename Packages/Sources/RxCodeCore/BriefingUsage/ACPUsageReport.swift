import Foundation

/// Provider APIs supplement ACP, which does not expose account usage limits.
public enum ACPUsageProvider: String, CaseIterable, Sendable {
    case opencode, antigravity

    public var pluginID: String { "acp-\(rawValue)" }
    public var title: String { self == .opencode ? "OpenCode Go" : "Antigravity" }

    public static var antigravityUserAgent: String {
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "amd64"
        #else
        let arch = "unknown"
        #endif
        #if os(macOS)
        let osType = "darwin"
        #elseif os(iOS)
        let osType = "ios"
        #else
        let osType = "unknown"
        #endif
        return "antigravity/acp/1.5.0 (aidev_client; os_type=\(osType); arch=\(arch); host_path=rxcode/1.0.0; proxy_client=antigravity/sdk)"
    }

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
            command = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        case .npx, .uvx: return nil
        }
        switch command {
        case "opencode": return .opencode
        case "agy", "agy_acp_server", "agy_acp_server.par", "antigravity", "antigravity-acp":
            return .antigravity
        default: return nil
        }
    }

    public func request(token: String) -> URLRequest {
        request(token: token, projectID: nil, endpointURL: nil)
    }

    public func request(token: String, projectID: String?, endpointURL: URL? = nil) -> URLRequest {
        let defaultEndpoint = self == .opencode
            ? "https://opencode.ai/inference/go/v1/usage"
            : "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
        var request = URLRequest(url: endpointURL ?? URL(string: defaultEndpoint)!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if self == .antigravity {
            request.httpMethod = "POST"
            if let projectID, !projectID.isEmpty,
               let body = try? JSONSerialization.data(withJSONObject: ["project": projectID]) {
                request.httpBody = body
            } else {
                request.httpBody = Data("{}".utf8)
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.antigravityUserAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    public static func antigravityBusinessRequest(
        token: String,
        baseURL: URL,
        projectID: String,
        location: String,
        userTier: String? = nil
    ) -> URLRequest? {
        guard !projectID.isEmpty, !location.isEmpty else { return nil }
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedProject = projectID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectID
        let encodedLocation = location.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? location
        let rawURL = "\(base)/v1beta/projects/\(encodedProject)/locations/\(encodedLocation):fetchQuotaStatus"
        guard var components = URLComponents(string: rawURL) else { return nil }
        if let userTier, !userTier.isEmpty {
            components.queryItems = [URLQueryItem(name: "entitlement.userTier", value: userTier)]
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(antigravityUserAgent, forHTTPHeaderField: "User-Agent")
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
                let resetDate = Self.parseResetDate(window["resetsAt"])
                return .init(id, title, value: percent, unit: "%", detail: Self.resetDetail(resetDate), resetsAt: resetDate)
            }
        case .antigravity:
            let payload = (root["response"] as? [String: Any]) ?? (root["summary"] as? [String: Any]) ?? root
            guard let groups = payload["groups"] as? [[String: Any]] else { throw UsagePluginError.invalidResponse }
            metrics = groups.enumerated().flatMap { index, group -> [UsageMetric] in
                let title = (group["displayName"] as? String)
                    ?? (group["display_name"] as? String)
                    ?? (group["name"] as? String)
                    ?? "Quota"
                let buckets = (group["buckets"] as? [[String: Any]] ?? [])
                    .enumerated()
                    .sorted { lhs, rhs in
                        let leftRank = Self.bucketSortRank(lhs.element)
                        let rightRank = Self.bucketSortRank(rhs.element)
                        return leftRank != rightRank ? leftRank < rightRank : lhs.offset < rhs.offset
                    }
                    .map(\.element)
                return buckets.compactMap { bucket in
                    guard bucket["disabled"] as? Bool != true,
                          let id = (bucket["bucketId"] as? String)
                            ?? (bucket["bucket_id"] as? String)
                            ?? (bucket["id"] as? String) else { return nil }
                    let remaining = bucket["remaining"] as? [String: Any]
                    let resetDate = Self.parseResetDate(bucket["resetTime"] ?? bucket["reset_time"])
                    let rawName = (bucket["displayName"] as? String)
                        ?? (bucket["display_name"] as? String)
                        ?? (bucket["name"] as? String)
                    let window = (bucket["window"] as? String) ?? ""

                    let hasFractionField = bucket["remainingFraction"] != nil
                        || bucket["remaining_fraction"] != nil
                        || remaining?["remainingFraction"] != nil
                        || remaining?["remaining_fraction"] != nil
                        || (remaining?["case"] as? String == "remainingFraction")
                    if hasFractionField {
                        let fraction = Self.number(bucket["remainingFraction"])
                            ?? Self.number(bucket["remaining_fraction"])
                            ?? Self.number(remaining?["remainingFraction"])
                            ?? Self.number(remaining?["remaining_fraction"])
                            ?? (remaining?["case"] as? String == "remainingFraction" ? Self.number(remaining?["value"]) : nil)
                        guard let fraction, (0...1).contains(fraction) else { return nil }
                        let bucketLabel = Self.normalizedWindowLabel(rawName: rawName, window: window, id: id)
                        return .init("\(index):\(id)", "\(title) · \(bucketLabel)", value: (1 - fraction) * 100,
                                     unit: "%", detail: Self.resetDetail(resetDate), resetsAt: resetDate)
                    }

                    let amount = Self.number(bucket["remainingAmount"])
                        ?? Self.number(bucket["remaining_amount"])
                        ?? (remaining?["case"] as? String == "remainingAmount" ? Self.number(remaining?["value"]) : nil)
                    guard let amount, amount >= 0 else { return nil }
                    let label = rawName ?? id
                    return .init("\(index):\(id)", "\(title) · \(label)", value: amount,
                                 unit: "units remaining", detail: Self.resetDetail(resetDate), resetsAt: resetDate)
                }
            }
        }
        guard !metrics.isEmpty else { throw UsagePluginError.invalidResponse }
        return metrics
    }

    private static func bucketSortRank(_ bucket: [String: Any]) -> Int {
        let window = ((bucket["window"] as? String) ?? "").lowercased()
        let id = ((bucket["bucketId"] as? String) ?? (bucket["bucket_id"] as? String) ?? (bucket["id"] as? String) ?? "").lowercased()
        if window == "5h" || id == "5h" || id.hasSuffix("-5h") { return 0 }
        if window == "daily" || window == "24h" || id.hasSuffix("-daily") { return 1 }
        if window == "weekly" || window == "7d" || id == "weekly" || id.hasSuffix("-weekly") { return 2 }
        if window == "monthly" || id.hasSuffix("-monthly") { return 3 }
        return 4
    }

    private static func normalizedWindowLabel(rawName: String?, window: String, id: String) -> String {
        let lowerWindow = window.lowercased()
        let lowerID = id.lowercased()
        let trimmed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lowerName = trimmed.lowercased()

        if lowerWindow == "5h" || lowerID == "5h" || lowerID.hasSuffix("-5h")
            || lowerName == "five hour limit remaining" || lowerName == "5 hour limit remaining" {
            return "5-hour"
        }
        if lowerWindow == "weekly" || lowerWindow == "7d" || lowerID == "weekly" || lowerID.hasSuffix("-weekly")
            || lowerName == "weekly limit remaining" {
            return "Weekly"
        }
        if lowerWindow == "daily" || lowerWindow == "24h" || lowerID.hasSuffix("-daily")
            || lowerName == "daily limit remaining" {
            return "Daily"
        }
        if lowerWindow == "monthly" || lowerID.hasSuffix("-monthly")
            || lowerName == "monthly limit remaining" {
            return "Monthly"
        }
        for suffix in [" limit remaining", " remaining"] where lowerName.hasSuffix(suffix) {
            let stripped = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty { return stripped }
        }
        return trimmed.isEmpty ? id : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        if let string = value as? String, let parsed = Double(string), parsed.isFinite {
            return parsed
        }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func parseResetDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
            ?? ISO8601DateFormatter.withFractionalSeconds.date(from: text)
    }

    private static func resetDetail(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

public struct ACPQuotaWindowPair: Sendable, Equatable {
    public var groupTitle: String?
    public var fiveHour: UsageMetric?
    public var weekly: UsageMetric?

    public init(groupTitle: String? = nil, fiveHour: UsageMetric? = nil, weekly: UsageMetric? = nil) {
        self.groupTitle = groupTitle
        self.fiveHour = fiveHour
        self.weekly = weekly
    }
}

public extension UsagePluginSnapshot {
    /// Resolves compact 5-hour and weekly quota metrics for the chat footer.
    /// For Antigravity, only Gemini-related usage is shown inline in the footer;
    /// non-Gemini model groups are displayed when opening the usage detail sheet.
    func acpQuotaWindows(forModel _: String? = nil) -> ACPQuotaWindowPair? {
        let pctMetrics = metrics.filter { $0.unit == "%" && $0.value?.isFinite == true }
        guard !pctMetrics.isEmpty else { return nil }

        if pluginID == ACPUsageProvider.opencode.pluginID {
            let fiveHour = pctMetrics.first { $0.id == "rolling" }
            let weekly = pctMetrics.first { $0.id == "weekly" }
            guard fiveHour != nil || weekly != nil else { return nil }
            return ACPQuotaWindowPair(groupTitle: scope.isEmpty ? title : scope, fiveHour: fiveHour, weekly: weekly)
        }

        guard pluginID == ACPUsageProvider.antigravity.pluginID else { return nil }

        var grouped: [(key: String, metrics: [UsageMetric])] = []
        for metric in pctMetrics {
            let key = metric.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
            if let idx = grouped.firstIndex(where: { $0.key == key }) {
                grouped[idx].metrics.append(metric)
            } else {
                grouped.append((key, [metric]))
            }
        }

        let geminiGroup = grouped.first { entry in
            entry.metrics.contains { metric in
                let lowerID = metric.id.lowercased()
                let lowerTitle = metric.title.lowercased()
                return lowerID.contains(":gemini-") || lowerTitle.contains("gemini")
            }
        }

        guard let selected = geminiGroup?.metrics, !selected.isEmpty else { return nil }
        let fiveHour = selected.first { metric in
            let id = metric.id.lowercased()
            let title = metric.title.lowercased()
            return id.hasSuffix(":5h") || id.hasSuffix("-5h") || title.hasSuffix("· 5-hour")
        }
        let weekly = selected.first { metric in
            let id = metric.id.lowercased()
            let title = metric.title.lowercased()
            return id.hasSuffix(":weekly") || id.hasSuffix("-weekly") || id.hasSuffix("-7d") || title.hasSuffix("· weekly")
        }
        guard fiveHour != nil || weekly != nil else { return nil }
        let groupTitle = (fiveHour ?? weekly)?.title.components(separatedBy: " · ").first
        return ACPQuotaWindowPair(groupTitle: groupTitle, fiveHour: fiveHour, weekly: weekly)
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

    public static func fetch(request: URLRequest, provider: ACPUsageProvider, integration: UsageIntegration,
                             session: URLSession) async throws -> UsagePluginSnapshot {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
        if http.statusCode == 401 { throw ACPUsageFetchError.signIn(provider.title) }
        if http.statusCode == 403 { throw ACPUsageFetchError.noAccess(provider.title) }
        guard http.statusCode == 200 else { throw UsagePluginError.http(http.statusCode) }
        return .init(id: integration.id, pluginID: integration.pluginID, title: integration.title,
                     projectID: integration.projectID, scope: provider.title,
                     period: "Current account limits", metrics: try provider.metrics(from: data))
    }

    /// Explicit URL injection is limited to native tests; synced configuration cannot redirect credentials.
    static func fetch(provider: ACPUsageProvider, token: String, integration: UsageIntegration,
                      session: URLSession, requestURL: URL?) async throws -> UsagePluginSnapshot {
        var request = provider.request(token: token)
        if let requestURL { request.url = requestURL }
        return try await fetch(request: request, provider: provider, integration: integration, session: session)
    }
}
