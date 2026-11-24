import Foundation
import RxCodeExtensionSDK

enum AntigravityProvider {
    static func fetch(_ integration: ExtensionUsageIntegration, host: RxCodeHost) async throws -> ExtensionUsageSnapshot {
        guard integration.pluginID == "acp-antigravity", !integration.resource.isEmpty else { throw ExtensionCallError.invalidRequest }
        let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
        let slot = "acp:" + integration.resource
        var response = try await host.fetch(url, method: "POST", credentialSlot: slot)
        if response.status == 401 {
            // The broker discarded the cached session. Retry once with the current client login.
            response = try await host.fetch(url, method: "POST", credentialSlot: slot)
        }
        guard response.status == 200 else { throw ExtensionCallError.invalidRequest }
        return try ExtensionUsageSnapshot(integration: integration, scope: "Antigravity", period: "Current account limits",
                                          metrics: metrics(from: response.body))
    }

    static func metrics(from data: Data) throws -> [ExtensionUsageSnapshot.Metric] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else {
            throw ExtensionCallError.invalidRequest
        }
        let metrics: [ExtensionUsageSnapshot.Metric]
        let payload = (root["response"] as? [String: Any]) ?? (root["summary"] as? [String: Any]) ?? root
        guard let groups = payload["groups"] as? [[String: Any]] else { throw ExtensionCallError.invalidRequest }
        metrics = groups.enumerated().flatMap { index, group -> [ExtensionUsageSnapshot.Metric] in
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
                    return .init(id: "\(index):\(id)", title: "\(title) · \(bucketLabel)", value: (1 - fraction) * 100,
                                 unit: "%", detail: Self.resetDetail(resetDate), resetsAt: resetDate)
                }

                let amount = Self.number(bucket["remainingAmount"])
                    ?? Self.number(bucket["remaining_amount"])
                    ?? (remaining?["case"] as? String == "remainingAmount" ? Self.number(remaining?["value"]) : nil)
                guard let amount, amount >= 0 else { return nil }
                let label = rawName ?? id
                return .init(id: "\(index):\(id)", title: "\(title) · \(label)", value: amount,
                             unit: "units remaining", detail: Self.resetDetail(resetDate), resetsAt: resetDate)
            }
        }

        guard !metrics.isEmpty else { throw ExtensionCallError.invalidRequest }
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
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
    }

    private static func resetDetail(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
