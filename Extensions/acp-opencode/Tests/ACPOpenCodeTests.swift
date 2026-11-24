import Foundation
import RxCodeCore
import RxCodeExtensionSDK
import Testing
@testable import ACPOpenCode

struct ACPOpenCodeTests {
    @Test func openCodePercentIsNotFractionAndMissingWindowsStayMissing() throws {
        let metrics = try OpenCodeProvider.metrics(from: Data(#"{"usage":{"rolling":{"percent":0.5},"monthly":{"percent":84,"resetsAt":"2026-11-01T00:00:00.000Z"}}}"#.utf8))
        #expect(metrics.map(\.id) == ["rolling", "monthly"])
        #expect(metrics[0].value == 0.5)
        #expect(metrics[1].detail?.hasPrefix("Resets ") == true)
        #expect(metrics[1].resetsAt != nil)
    }

    @Test func rejectsMalformedReports() {
        let samples = [#"{}"#, #"{"error":{"message":"private"}}"#, #"{"usage":{"rolling":{"percent":true}}}"#, #"{"usage":{"rolling":{"percent":101}}}"#]
        for sample in samples {
            #expect(throws: (any Error).self) { try OpenCodeProvider.metrics(from: Data(sample.utf8)) }
        }
    }

    @Test func brokerFetchPreservesMetricContract() async throws {
        let original = UsageIntegration(pluginID: "acp-opencode", title: "Account", resource: "my-client")
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(original))
        let fixture = Data(#"{"usage":{"rolling":{"percent":0.5},"monthly":{"percent":84}}}"#.utf8)
        let host = RxCodeHost { request in
            struct Arguments: Decodable { let url, method, credentialSlot: String }
            #expect(request.operation == .netFetch)
            let args = try request.decode(Arguments.self)
            #expect(args.url == "https://opencode.ai/inference/go/v1/usage")
            #expect(args.method == "GET")
            #expect(args.credentialSlot == "acp:my-client")
            return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 200, body: fixture))
        }
        let snapshot = try await OpenCodeProvider.fetch(input, host: host)
        let metrics = try JSONDecoder().decode([UsageMetric].self, from: JSONEncoder().encode(snapshot.metrics))
        #expect(metrics == (try ACPUsageProvider.opencode.metrics(from: fixture)))
        #expect(snapshot.id == original.id && snapshot.pluginID == original.pluginID)
    }

    @Test(arguments: [ExtensionCallError.permissionPending, .permissionDenied, .extensionBlocked])
    func propagatesPermissionAndRevocation(_ error: ExtensionCallError) async throws {
        let input = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(
            UsageIntegration(pluginID: "acp-opencode", title: "Quota", resource: "my-client")))
        let host = RxCodeHost { ExtensionResponse(replyingTo: $0, error: error) }
        await #expect(throws: error) { _ = try await OpenCodeProvider.fetch(input, host: host) }
    }
}
