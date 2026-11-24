import Foundation
import RxCodeExtensionSDK

struct UsageReport: Decodable, Sendable {
    struct Breakdown: Decodable, Sendable, Identifiable {
        let providerRaw: String
        let model: String
        let turns: Int
        let sessionSeconds: Double
        let totalTokens: Int
        var id: String { "\(providerRaw)|\(model)" }

        func value(for metric: String?) -> Double {
            switch metric {
            case "time": sessionSeconds
            case "tokens": Double(totalTokens)
            default: Double(turns)
            }
        }
    }

    struct Summary: Decodable, Sendable {
        let sessionSeconds: Double
        let turns: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheCreationTokens: Int
        let cacheReadTokens: Int
        let models: [Breakdown]
        let providers: [Breakdown]
        var tokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    }
    let summary: Summary
    let modelLabels: [String: String]
    let providerLabels: [String: String]

    func label(for model: Breakdown) -> String { modelLabels[model.id] ?? model.model }
}

enum AIUsageProvider {
    static func report(_ host: RxCodeHost) async throws -> UsageReport {
        try await host.call(.localUsage, ["range": "week"], returning: UsageReport.self)
    }

    static func fetch(_ integration: ExtensionUsageIntegration, host: RxCodeHost) async throws -> ExtensionUsageSnapshot {
        guard integration.pluginID == "ai-usage" else { throw ExtensionCallError.invalidRequest }
        let report = try await report(host)
        let summary = report.summary
        let first = summary.models.first
        var metrics: [ExtensionUsageSnapshot.Metric] = [
            .init(id: "top-model", title: "Most used model", value: first.map { Double($0.turns) }, unit: "turns",
                  detail: first.map(report.label) ?? "No agent turns yet"),
            .init(id: "tokens", title: "Tokens burned", value: Double(summary.tokens), unit: "tokens"),
            .init(id: "time", title: "Session time", value: summary.sessionSeconds, unit: "seconds"),
            .init(id: "turns", title: "Agent turns", value: Double(summary.turns), unit: "turns")
        ]
        metrics += summary.models.map {
            .init(id: "model:" + $0.id, title: report.label(for: $0), value: Double($0.turns), unit: "turns", detail: $0.providerRaw)
        }
        return ExtensionUsageSnapshot(integration: integration, scope: integration.projectID == nil ? "All projects" : "Project",
                                      period: "Last 7 days", metrics: metrics)
    }
}
