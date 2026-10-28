import Foundation
import Testing
@testable import RxCodeCore

@Suite("Cloudflare resource usage")
struct CloudflareResourceUsageTests {
    @Test func existingScopesRemainCompatible() {
        #expect(CloudflareUsageScope(resource: "") == .account)
        #expect(CloudflareUsageScope(resource: "zone-id") == .zone)
        #expect(CloudflareUsageScope(resource: "worker:api") == .worker)
        #expect(CloudflareUsageScope(resource: "r2:eu_assets") == .r2)
        #expect(CloudflareUsageScope.r2.name(in: "r2:eu_assets") == "eu_assets")
    }

    @Test func resourceNamesAreVariablesAndStorageIsLatestSample() throws {
        let name = "api\"}query{"
        let request = try CloudflareResourceUsage.request(account: "account", resource: "worker:" + name, now: .now)
        let requestBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let variables = try #require(body["variables"] as? [String: String])
        #expect(variables["resource"] == name)
        #expect(!(body["query"] as? String ?? "").contains(name))
        #expect(request.httpMethod == "POST")
        let r2 = try CloudflareResourceUsage.request(account: "account", resource: "r2:assets", now: .now)
        let query = String(decoding: try #require(r2.httpBody), as: UTF8.self)
        #expect(query.contains("datetime_DESC"))
        #expect(query.contains("bucketName: $resource"))
        #expect(throws: (any Error).self) {
            try CloudflareResourceUsage.request(account: "account", resource: "worker:", now: .now)
        }
    }

    @Test func parsesUsageWithoutInventingMissingValues() throws {
        let r2 = Data(#"{"data":{"viewer":{"accounts":[{"activity":[{"sum":{"requests":42}}],"storage":[{"max":{"payloadSize":2048,"metadataSize":128,"objectCount":7},"dimensions":{"datetime":"2026-10-28T06:00:00Z"}}]}]}}}"#.utf8)
        let metrics = try CloudflareResourceUsage.metrics(r2, resource: "r2:assets")
        #expect(metrics.first?.value == 42)
        #expect(metrics.first { $0.id == "payloadSize" }?.value == 2048)
        #expect(metrics.first { $0.id == "objectCount" }?.value == 7)
        let empty = Data(#"{"data":{"viewer":{"accounts":[{"activity":[],"storage":[]}]}}}"#.utf8)
        #expect(try CloudflareResourceUsage.metrics(empty, resource: "r2:assets").allSatisfy { $0.value == nil })
    }

    @Test func rejectsPartialDataMissingAccountsAndInvalidNumbers() {
        for json in [
            #"{"errors":[{"message":"denied"}],"data":{"viewer":{"accounts":[{"activity":[{"sum":{"requests":5,"errors":0}}]}]}}}"#,
            #"{"data":{"viewer":{"accounts":[]}}}"#,
            #"{"data":{"viewer":{"accounts":[{"activity":[{"sum":{"requests":true,"errors":0}}]}]}}}"#,
            #"{"data":{"viewer":{"accounts":[{"activity":[{"sum":{"requests":-1,"errors":0}}]}]}}}"#,
            #"{"data":{"viewer":{"accounts":[{"activity":[{"sum":{"requests":1}}]}]}}}"#
        ] {
            #expect(throws: (any Error).self) { try CloudflareResourceUsage.metrics(Data(json.utf8), resource: "worker:api") }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["RXCODE_USAGE_SIMULATION_URL"] != nil))
    func fetchesThroughRealHTTP() async throws {
        let endpointText = try #require(ProcessInfo.processInfo.environment["RXCODE_USAGE_SIMULATION_URL"])
        let endpoint = try #require(URL(string: endpointText))
        let plugin = CloudUsagePlugin(id: "cloudflare", cloudflareAnalyticsEndpoint: endpoint)
        for resource in ["worker:api", "r2:assets"] {
            let integration = UsageIntegration(pluginID: "cloudflare", title: "Resource", account: "test-account", resource: resource, projectID: UUID())
            let snapshot = try await plugin.fetch(configuration: integration, credential: "simulation-only", now: Date(timeIntervalSince1970: 1793167200))
            #expect(snapshot.id == integration.id)
            #expect(snapshot.projectID == integration.projectID)
            #expect(snapshot.metrics.first?.value == 42)
            #expect(snapshot.period == "Last 24 hours · analytics")
            #expect(snapshot.error == nil)
        }
        for name in ["denied", "partial"] {
            let integration = UsageIntegration(pluginID: "cloudflare", title: "Failure", account: "test-account", resource: "worker:" + name)
            await #expect(throws: (any Error).self) {
                try await plugin.fetch(configuration: integration, credential: "simulation-only", now: .now)
            }
        }
    }
}
