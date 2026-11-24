import Foundation
import RxCodeExtensionSDK
import Testing
@testable import TursoUsage

@Test(arguments: ["", "sample"])
func scopesTursoRequestsToOrganizationOrDatabase(resource: String) async throws {
    let integration = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: Data("""
    {"id":"04907b33-d54b-49f7-b971-be8d2a797165","pluginID":"turso","title":"Rows","account":"acme","resource":"\(resource)"}
    """.utf8))
    struct Request: Decodable { let url: URL; let credentialSlot: String }
    let host = RxCodeHost { request in
        let http = try request.decode(Request.self)
        #expect(http.credentialSlot == "primary")
        #expect(http.url.host == "api.turso.tech")
        let usage = #"{"rows_read":10,"rows_written":"2","storage_bytes":4096,"bytes_synced":0}"#
        let json: String
        if resource.isEmpty {
            #expect(http.url.path == "/v1/organizations/acme/usage")
            #expect(http.url.query == nil)
            json = #"{"organization":{"usage":\#(usage)}}"#
        } else {
            #expect(http.url.path == "/v1/organizations/acme/databases/sample/usage")
            #expect(http.url.query?.contains("from=") == true)
            json = #"{"database":{"total":\#(usage)}}"#
        }
        return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 200, body: Data(json.utf8)))
    }
    let snapshot = try await TursoUsage.fetch(integration, host: host, now: .now)
    #expect(snapshot.id == integration.id)
    #expect(snapshot.period == (resource.isEmpty ? "Current billing period" : "Last 30 days"))
    #expect(snapshot.metrics.map(\.id) == ["rows_read", "rows_written", "storage_bytes", "bytes_synced"])
    #expect(snapshot.metrics.map(\.value) == [10, 2, 4096, 0])
}
