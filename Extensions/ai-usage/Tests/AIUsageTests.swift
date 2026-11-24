import Foundation
import RxCodeCore
import RxCodeExtensionSDK
import Testing
@testable import AIUsage

struct AIUsageTests {
    @Test func buildsProjectMetricsFromHostBuckets() async throws {
        let project = UUID()
        let integration = UsageIntegration(pluginID: "ai-usage", title: "Weekly usage", projectID: project)
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(integration))
        let summary = UsageStatsSummary.aggregate([
            .init(bucketStart: .now, projectId: project, providerRaw: "codex", model: "gpt", sessionSeconds: 4.5,
                  turns: 2, inputTokens: 3, outputTokens: 5, cacheCreationTokens: 7, cacheReadTokens: 11)
        ])
        let dto = LocalUsageSummaryDTO(range: .week, summary: summary, modelLabels: ["codex|gpt": "GPT"], providerLabels: ["codex": "Codex"])
        let host = RxCodeHost { request in
            #expect(request.operation == .localUsage)
            #expect(try request.decode([String: String].self) == ["range": "week"])
            return try ExtensionResponse(replyingTo: request, value: dto)
        }
        let snapshot = try await AIUsageProvider.fetch(input, host: host)
        #expect(snapshot.id == integration.id && snapshot.projectID == project && snapshot.scope == "Project")
        #expect(snapshot.metrics.map(\.id) == ["top-model", "tokens", "time", "turns", "model:codex|gpt"])
        #expect(snapshot.metrics.map(\.value) == [2, 26, 4.5, 2, 2])
        #expect(snapshot.metrics.first?.detail == "GPT")
        #expect(snapshot.metrics.last?.title == "GPT")
    }

    @Test func emptyWeekKeepsMetricSelections() async throws {
        let integration = UsageIntegration(pluginID: "ai-usage", title: "Weekly usage")
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(integration))
        let host = RxCodeHost { try ExtensionResponse(replyingTo: $0, value: LocalUsageSummaryDTO(range: .week, summary: .init())) }
        let snapshot = try await AIUsageProvider.fetch(input, host: host)
        #expect(snapshot.scope == "All projects")
        #expect(snapshot.metrics.map(\.value) == [nil, 0, 0, 0])
        #expect(snapshot.metrics.first?.detail == "No agent turns yet")
    }
}
