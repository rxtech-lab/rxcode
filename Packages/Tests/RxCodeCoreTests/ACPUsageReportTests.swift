import Foundation
import Testing
@testable import RxCodeCore

struct ACPUsageReportTests {
    @Test func detectionUsesRegistryOrExecutableRatherThanDisplayName() {
        let client = ACPClientSpec(registryId: "antigravity-acp", displayName: "Work", launch: .custom(command: "custom", args: [], env: [:]))
        #expect(ACPUsageProvider.provider(for: client) == .antigravity)

        let parClient = ACPClientSpec(displayName: "Custom Par", launch: .binary(path: "/opt/acp/agy_acp_server.par", args: [], env: [:]))
        #expect(ACPUsageProvider.provider(for: parClient) == .antigravity)

        let cliClient = ACPClientSpec(displayName: "Standalone CLI", launch: .custom(command: "/Users/dev/.local/bin/agy", args: ["acp"], env: [:]))
        #expect(ACPUsageProvider.provider(for: cliClient) == .antigravity)

        let unrelated = ACPClientSpec(displayName: "OpenCode", launch: .custom(command: "other", args: [], env: [:]))
        #expect(ACPUsageProvider.provider(for: unrelated) == nil)
    }

    @Test func openCodePercentIsNotFractionAndMissingWindowsStayMissing() throws {
        let metrics = try ACPUsageProvider.opencode.metrics(from: Data(#"{"usage":{"rolling":{"percent":0.5},"monthly":{"percent":84,"resetsAt":"2026-11-01T00:00:00.000Z"}}}"#.utf8))
        #expect(metrics.map(\.id) == ["rolling", "monthly"])
        #expect(metrics[0].value == 0.5)
        #expect(metrics[1].detail?.hasPrefix("Resets ") == true)
        #expect(metrics[1].resetsAt != nil)
    }

    @Test func antigravityConvertsRemainingAndPreservesSeparateWindows() throws {
        let data = Data(#"{"summary":{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"5h","remainingFraction":0.75,"resetTime":"2026-10-28T22:00:00Z"},{"bucketId":"weekly","remaining":{"case":"remainingFraction","value":0.25}},{"bucketId":"disabled","remainingFraction":1,"disabled":true}]}]}}"#.utf8)
        let metrics = try ACPUsageProvider.antigravity.metrics(from: data)
        #expect(metrics.count == 2)
        #expect(metrics[0].value == 25)
        #expect(metrics[0].title == "Gemini · 5-hour")
        #expect(metrics[0].resetsAt != nil)
        #expect(metrics[1].value == 75)
        #expect(metrics[1].title == "Gemini · Weekly")
        #expect(metrics[0].detail != nil)
    }

    @Test func antigravityNormalizesLiveCCPAGroupsAndShowsOnlyGeminiInFooter() throws {
        let liveFixture = Data(#"""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remainingFraction": 0.9,
                  "resetTime": "2026-11-20T16:35:00Z"
                },
                {
                  "bucketId": "gemini-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "remainingFraction": 0.8,
                  "resetTime": "2026-11-13T21:35:00Z"
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remainingFraction": 0.6,
                  "resetTime": "2026-11-20T16:35:00Z"
                },
                {
                  "bucketId": "3p-5h",
                  "displayName": "Five Hour Limit Remaining",
                  "window": "5h",
                  "remainingFraction": 0.5,
                  "resetTime": "2026-11-13T21:35:00Z"
                }
              ]
            }
          ]
        }
        """#.utf8)

        let metrics = try ACPUsageProvider.antigravity.metrics(from: liveFixture)
        #expect(metrics.map(\.id) == ["0:gemini-5h", "0:gemini-weekly", "1:3p-5h", "1:3p-weekly"])
        #expect(metrics.map(\.title) == [
            "Gemini Models · 5-hour",
            "Gemini Models · Weekly",
            "Claude and GPT models · 5-hour",
            "Claude and GPT models · Weekly"
        ])
        #expect(abs((metrics[0].value ?? 0) - 20) < 0.001)
        #expect(abs((metrics[1].value ?? 0) - 10) < 0.001)
        #expect(abs((metrics[2].value ?? 0) - 50) < 0.001)
        #expect(abs((metrics[3].value ?? 0) - 40) < 0.001)

        let snapshot = UsagePluginSnapshot(
            id: UUID(),
            pluginID: ACPUsageProvider.antigravity.pluginID,
            title: "Google Antigravity usage",
            scope: "Antigravity",
            period: "Current account limits",
            metrics: metrics
        )

        // Footer always shows Gemini-related usage regardless of active model;
        // Claude and GPT models stay in `snapshot.metrics` for the opened detail sheet.
        for model in ["client-1::gemini-4-carbon", "client-1::claude-sonnet-4-6"] {
            let footerWindows = try #require(snapshot.acpQuotaWindows(forModel: model))
            #expect(footerWindows.groupTitle == "Gemini Models")
            #expect(footerWindows.fiveHour?.id == "0:gemini-5h")
            #expect(footerWindows.weekly?.id == "0:gemini-weekly")
        }

        let nonGeminiOnly = UsagePluginSnapshot(
            id: UUID(),
            pluginID: ACPUsageProvider.antigravity.pluginID,
            title: "Google Antigravity usage",
            scope: "Antigravity",
            period: "Current account limits",
            metrics: Array(metrics.dropFirst(2))
        )
        #expect(nonGeminiOnly.acpQuotaWindows() == nil)
    }

    @Test func antigravitySupportsSnakeCaseAndUnitAmountBuckets() throws {
        let baicData = Data(#"{"groups":[{"display_name":"Enterprise","buckets":[{"bucket_id":"ent-5h","window":"5h","remaining_fraction":0.4,"reset_time":"2026-11-14T00:00:00Z"},{"bucket_id":"credits","display_name":"Credits","remaining_amount":150}]}]}"#.utf8)
        let metrics = try ACPUsageProvider.antigravity.metrics(from: baicData)
        #expect(metrics.count == 2)
        #expect(abs((metrics[0].value ?? 0) - 60) < 0.001)
        #expect(metrics[1].value == 150)
        #expect(metrics[1].unit == "units remaining")
    }

    @Test func rejectsEmptyErrorsAndInvalidNumbers() {
        for json in [#"{}"#, #"{"error":{"message":"secret"}}"#, #"{"usage":{"rolling":{"percent":true}}}"#, #"{"usage":{"rolling":{"percent":101}}}"#] {
            #expect(throws: (any Error).self) { try ACPUsageProvider.opencode.metrics(from: Data(json.utf8)) }
        }
        #expect(throws: (any Error).self) {
            try ACPUsageProvider.antigravity.metrics(from: Data(#"{"groups":[{"buckets":[{"bucketId":"weekly","remainingFraction":-1}]}]}"#.utf8))
        }
    }

    @Test func providerRequestsUseFixedHostsAndExpectedMethods() throws {
        let openCode = ACPUsageProvider.opencode.request(token: "fixture")
        #expect(openCode.url?.absoluteString == "https://opencode.ai/inference/go/v1/usage")
        #expect(openCode.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")

        let antigravity = ACPUsageProvider.antigravity.request(token: "fixture")
        #expect(antigravity.httpMethod == "POST")
        #expect(antigravity.httpBody == Data("{}".utf8))
        #expect(antigravity.value(forHTTPHeaderField: "User-Agent")?.contains("aidev_client") == true)

        let withProject = ACPUsageProvider.antigravity.request(token: "fixture", projectID: "proj-123")
        let parsedBody = try JSONSerialization.jsonObject(with: #require(withProject.httpBody)) as? [String: String]
        #expect(parsedBody == ["project": "proj-123"])

        let business = try #require(ACPUsageProvider.antigravityBusinessRequest(
            token: "fixture",
            baseURL: URL(string: "https://cloudaicompanion.googleapis.com")!,
            projectID: "my-proj",
            location: "global",
            userTier: "enterprise"
        ))
        #expect(business.httpMethod == "GET")
        #expect(business.url?.absoluteString == "https://cloudaicompanion.googleapis.com/v1beta/projects/my-proj/locations/global:fetchQuotaStatus?entitlement.userTier=enterprise")
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
