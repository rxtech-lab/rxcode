import Foundation
import Testing
@testable import RxCodeCore

struct ACPUsageReportTests {
    @Test func detectionUsesRegistryOrExecutableRatherThanDisplayName() {
        let client = ACPClientSpec(registryId: "antigravity-acp", displayName: "Work", launch: .custom(command: "custom", args: [], env: [:]))
        #expect(ACPUsageProvider.provider(for: client) == .antigravity)
        let unrelated = ACPClientSpec(displayName: "OpenCode", launch: .custom(command: "other", args: [], env: [:]))
        #expect(ACPUsageProvider.provider(for: unrelated) == nil)
    }

    @Test func openCodePercentIsNotFractionAndMissingWindowsStayMissing() throws {
        let metrics = try ACPUsageProvider.opencode.metrics(from: Data(#"{"usage":{"rolling":{"percent":0.5},"monthly":{"percent":84,"resetsAt":"2026-11-01T00:00:00.000Z"}}}"#.utf8))
        #expect(metrics.map(\.id) == ["rolling", "monthly"])
        #expect(metrics[0].value == 0.5)
        #expect(metrics[1].detail?.hasPrefix("Resets ") == true)
    }

    @Test func antigravityConvertsRemainingAndPreservesSeparateWindows() throws {
        let data = Data(#"{"summary":{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"5h","remainingFraction":0.75,"resetTime":"2026-10-28T22:00:00Z"},{"bucketId":"weekly","remaining":{"case":"remainingFraction","value":0.25}},{"bucketId":"disabled","remainingFraction":1,"disabled":true}]}]}}"#.utf8)
        let metrics = try ACPUsageProvider.antigravity.metrics(from: data)
        #expect(metrics.count == 2)
        #expect(metrics[0].value == 25)
        #expect(metrics[1].value == 75)
        #expect(metrics[0].detail != nil)
    }

    @Test func rejectsEmptyErrorsAndInvalidNumbers() {
        for json in [#"{}"#, #"{"error":{"message":"secret"}}"#, #"{"usage":{"rolling":{"percent":true}}}"#, #"{"usage":{"rolling":{"percent":101}}}"#] {
            #expect(throws: (any Error).self) { try ACPUsageProvider.opencode.metrics(from: Data(json.utf8)) }
        }
        #expect(throws: (any Error).self) {
            try ACPUsageProvider.antigravity.metrics(from: Data(#"{"groups":[{"buckets":[{"bucketId":"weekly","remainingFraction":-1}]}]}"#.utf8))
        }
    }

    @Test func providerRequestsUseFixedHostsAndExpectedMethods() {
        let openCode = ACPUsageProvider.opencode.request(token: "fixture")
        #expect(openCode.url?.absoluteString == "https://opencode.ai/inference/go/v1/usage")
        #expect(openCode.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        let antigravity = ACPUsageProvider.antigravity.request(token: "fixture")
        #expect(antigravity.httpMethod == "POST")
        #expect(antigravity.httpBody == Data("{}".utf8))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_ACP_USAGE_SIMULATION_URL"] != nil))
    func providerAPIsOverHTTP() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["RXCODE_ACP_USAGE_SIMULATION_URL"])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for provider in ACPUsageProvider.allCases {
            let path = provider == .opencode ? "/inference/go/v1/usage" : "/v1internal:retrieveUserQuotaSummary"
            let url = try #require(URL(string: base + path))
            let integration = UsageIntegration(pluginID: provider.pluginID, title: provider.title)
            let snapshot = try await ACPUsageAPI.fetch(provider: provider, token: "simulation-only", integration: integration,
                                                       session: session, requestURL: url)
            #expect(snapshot.metrics.count == 2)
            #expect(snapshot.metrics[0].value == (provider == .opencode ? 0.5 : 25))
            #expect(snapshot.error == nil)
            for token in ["expired", "denied"] {
                do {
                    _ = try await ACPUsageAPI.fetch(provider: provider, token: token, integration: integration,
                                                   session: session, requestURL: url)
                    Issue.record("Expected authentication or permission failure")
                } catch is ACPUsageFetchError { }
            }
        }
    }

}
