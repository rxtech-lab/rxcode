import Foundation
import RxCodeCore
import RxCodeExtensionSDK
import Testing
@testable import ACPAntigravity

struct ACPAntigravityTests {
    @Test func antigravityConvertsRemainingAndPreservesSeparateWindows() throws {
        let data = Data(#"{"summary":{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"5h","remainingFraction":0.75,"resetTime":"2026-10-28T22:00:00Z"},{"bucketId":"weekly","remaining":{"case":"remainingFraction","value":0.25}},{"bucketId":"disabled","remainingFraction":1,"disabled":true}]}]}}"#.utf8)
        let metrics = try AntigravityProvider.metrics(from: data)
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

        let metrics = try AntigravityProvider.metrics(from: liveFixture)
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
            metrics: try JSONDecoder().decode([UsageMetric].self, from: JSONEncoder().encode(metrics))
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
            metrics: Array(snapshot.metrics.dropFirst(2))
        )
        #expect(nonGeminiOnly.acpQuotaWindows() == nil)
    }

    @Test func antigravitySupportsSnakeCaseAndUnitAmountBuckets() throws {
        let baicData = Data(#"{"groups":[{"display_name":"Enterprise","buckets":[{"bucket_id":"ent-5h","window":"5h","remaining_fraction":0.4,"reset_time":"2026-11-14T00:00:00Z"},{"bucket_id":"credits","display_name":"Credits","remaining_amount":150}]}]}"#.utf8)
        let metrics = try AntigravityProvider.metrics(from: baicData)
        #expect(metrics.count == 2)
        #expect(abs((metrics[0].value ?? 0) - 60) < 0.001)
        #expect(metrics[1].value == 150)
        #expect(metrics[1].unit == "units remaining")
    }

    @Test func rejectsMalformedReports() {
        let samples = [#"{}"#, #"{"groups":[{"buckets":[{"bucketId":"weekly","remainingFraction":-1}]}]}"#]
        for sample in samples {
            #expect(throws: (any Error).self) { try AntigravityProvider.metrics(from: Data(sample.utf8)) }
        }
    }

    @Test func brokerFetchPreservesMetricContract() async throws {
        let original = UsageIntegration(pluginID: "acp-antigravity", title: "Account", resource: "my-client")
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(original))
        let fixture = Data(#"{"summary":{"groups":[{"buckets":[{"bucketId":"5h","remainingFraction":0.75},{"bucketId":"7d","remainingFraction":0.25}]}]}}"#.utf8)
        let host = RxCodeHost { request in
            struct Arguments: Decodable { let url, method, credentialSlot: String }
            #expect(request.operation == .netFetch)
            let args = try request.decode(Arguments.self)
            #expect(args.url == "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")
            #expect(args.method == "POST")
            #expect(args.credentialSlot == "acp:my-client")
            return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 200, body: fixture))
        }
        let snapshot = try await AntigravityProvider.fetch(input, host: host)
        let metrics = try JSONDecoder().decode([UsageMetric].self, from: JSONEncoder().encode(snapshot.metrics))
        #expect(metrics == (try ACPUsageProvider.antigravity.metrics(from: fixture)))
        #expect(snapshot.id == original.id && snapshot.pluginID == original.pluginID)
    }

    @Test func retriesTheQuotaRequestOnceAfterAuthenticationExpires() async throws {
        actor Replies {
            var count = 0
            func respond(to request: ExtensionRequest) throws -> ExtensionResponse {
                count += 1
                let data = Data(#"{"groups":[{"buckets":[{"bucketId":"weekly","remainingFraction":0.5}]}]}"#.utf8)
                return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: count == 1 ? 401 : 200, body: data))
            }
        }
        let replies = Replies()
        let host = RxCodeHost { try await replies.respond(to: $0) }
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(
            UsageIntegration(pluginID: "acp-antigravity", title: "Quota", resource: "selected-client")))
        let snapshot = try await AntigravityProvider.fetch(input, host: host)
        #expect(await replies.count == 2)
        #expect(snapshot.metrics.first?.value == 50)
    }

    @Test(arguments: [ExtensionCallError.permissionPending, .permissionDenied, .extensionBlocked])
    func propagatesPermissionAndRevocation(_ error: ExtensionCallError) async throws {
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(
            UsageIntegration(pluginID: "acp-antigravity", title: "Quota", resource: "my-client")))
        let host = RxCodeHost { ExtensionResponse(replyingTo: $0, error: error) }
        await #expect(throws: error) { _ = try await AntigravityProvider.fetch(input, host: host) }
    }
}
