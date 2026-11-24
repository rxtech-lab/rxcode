import Foundation
import RxCodeExtensionSDK
import Testing
@testable import NeonUsage

@Test(arguments: [false, true])
func readsAllNeonPagesAndRejectsRepeatedCursors(repeatCursor: Bool) async throws {
    let integration = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: Data("""
    {"id":"04907b33-d54b-49f7-b971-be8d2a797165","pluginID":"neon","title":"Compute","account":"org","resource":"demo"}
    """.utf8))
    struct Request: Decodable { let url: URL; let credentialSlot: String }
    let host = RxCodeHost { request in
        #expect(request.operation == .netFetch)
        let http = try request.decode(Request.self)
        #expect(http.credentialSlot == "primary")
        #expect(http.url.host == "console.neon.tech")
        let items = URLComponents(url: http.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(.init(name: "project_ids", value: "demo")))
        let next = repeatCursor || !items.contains(.init(name: "cursor", value: "page2"))
        let body = Data("""
        {"projects":[{"periods":[{"consumption":[{"metrics":[{"metric_name":"compute_unit_seconds","value":84}]}]}]}],
         "pagination":{"cursor":"\(next ? "page2" : "")"}}
        """.utf8)
        return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 200, body: body))
    }
    if repeatCursor {
        await #expect(throws: ExtensionCallError.invalidRequest) { try await NeonUsage.fetch(integration, host: host, now: .now) }
    } else {
        let snapshot = try await NeonUsage.fetch(integration, host: host, now: .distantPast)
        #expect(snapshot.metrics.first?.id == "compute_unit_seconds")
        #expect(snapshot.metrics.first?.unit == "CU seconds")
        #expect(snapshot.metrics.first?.value == 168)
        #expect(snapshot.fetchedAt == .distantPast)
        #expect(snapshot.scope == "org / demo")
    }
}
