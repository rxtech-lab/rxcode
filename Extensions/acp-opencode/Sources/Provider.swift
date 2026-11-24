import Foundation
import RxCodeExtensionSDK

enum OpenCodeProvider {
    static func fetch(_ integration: ExtensionUsageIntegration, host: RxCodeHost) async throws -> ExtensionUsageSnapshot {
        guard integration.pluginID == "acp-opencode", !integration.resource.isEmpty else { throw ExtensionCallError.invalidRequest }
        let url = URL(string: "https://opencode.ai/inference/go/v1/usage")!
        let response = try await host.fetch(url, method: "GET", credentialSlot: "acp:" + integration.resource)
        guard response.status == 200 else { throw ExtensionCallError.invalidRequest }
        return try ExtensionUsageSnapshot(integration: integration, scope: "OpenCode Go", period: "Current account limits",
                                          metrics: metrics(from: response.body))
    }

    static func metrics(from data: Data) throws -> [ExtensionUsageSnapshot.Metric] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil else {
            throw ExtensionCallError.invalidRequest
        }
        let metrics: [ExtensionUsageSnapshot.Metric]
        guard let usage = root["usage"] as? [String: Any] else { throw ExtensionCallError.invalidRequest }
        metrics = [("rolling", "5-hour usage"), ("weekly", "Weekly usage"), ("monthly", "Monthly usage")].compactMap { id, title in
            guard let window = usage[id] as? [String: Any],
                  let percent = Self.number(window["percent"]), (0...100).contains(percent) else { return nil }
            let resetDate = Self.parseResetDate(window["resetsAt"])
            return .init(id: id, title: title, value: percent, unit: "%", detail: Self.resetDetail(resetDate), resetsAt: resetDate)
        }

        guard !metrics.isEmpty else { throw ExtensionCallError.invalidRequest }
        return metrics
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
