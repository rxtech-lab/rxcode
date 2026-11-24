import Foundation
import RxCodeExtensionSDK
import Testing
@testable import GitHubCIUsage

@Test func firstAttemptsAndCredentialSlot() async throws {
    let integration = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: Data("""
    {"id":"8673F762-59D0-4B88-8200-07E9449B1779","pluginID":"github-ci","title":"Queue","account":"example/project","resource":""}
    """.utf8))
    struct Request: Decodable {
        let url: URL
        let credentialSlot: String
        let headers: [String: String]
    }
    let host = RxCodeHost { request in
        #expect(request.operation == .netFetch)
        let fetch = try request.decode(Request.self)
        #expect(fetch.url.host == "api.github.com")
        #expect(fetch.url.path == "/repos/example/project/actions/runs")
        #expect(fetch.credentialSlot == "primary")
        #expect(fetch.headers["Authorization"] == nil)
        let body = Data("""
        {"workflow_runs":[
            {"id":1,"created_at":"2025-01-01T12:00:00Z","run_started_at":"2025-01-01T12:00:30Z","run_attempt":1,"pull_requests":[{"number":4}]},
            {"id":2,"created_at":"2025-01-01T11:00:00Z","run_started_at":"2025-01-01T12:00:00Z","run_attempt":2,"pull_requests":[{"number":4}]}
        ]}
        """.utf8)
        return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 200, body: body))
    }
    let result = try await GitHubCIUsage.fetch(integration, host: host, now: Date(timeIntervalSince1970: 1_735_732_800))
    #expect(result.id == integration.id)
    #expect(result.metrics.map(\.id) == ["overall", "repo:example/project", "example/project#4"])
    #expect(result.metrics.allSatisfy { $0.value == 30 && $0.unit == "seconds" })
}

@Test func averageWeightsPullRequestsEqually() {
    let first = CIWaitSample(id: "a", repository: "r", pr: 1, seconds: 10)
    let result = CIWaitSample.metrics([first, first, .init(id: "b", repository: "r", pr: 1, seconds: 30),
                                       .init(id: "c", repository: "r", pr: 2, seconds: 100)])
    #expect(result.first?.value == 60)
    #expect(CIWaitSample.metrics([]).first?.value == nil)
}
