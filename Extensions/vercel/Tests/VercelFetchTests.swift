import Foundation
import RxCodeExtensionSDK
import Testing
@testable import VercelUsage

@Test(arguments: ["gateway-only", "denied", "malformed", "missing", "blocked"])
func fetchesScopedBillingAndOptionalGatewayCredits(gateway: String) async throws {
    // An old saved OAuth configuration must still use the billing access-token slot.
    let integration = try JSONDecoder().decode(ExtensionUsageIntegration.self, from: Data("""
    {"id":"04907b33-d54b-49f7-b971-be8d2a797165","pluginID":"vercel","title":"Vercel",
     "account":"","resource":"project_a","oauth":{"clientID":"saved","callbackURL":"unused","scopes":"openid"}}
    """.utf8))
    struct Request: Decodable {
        let url: URL
        let credentialSlot: String
        let headers: [String: String]
    }
    let host = RxCodeHost { request in
        if request.operation == .storageGet { return try ExtensionResponse(replyingTo: request, value: String?.none) }
        let http = try request.decode(Request.self)
        #expect(http.headers["Authorization"] == nil)
        let body: String
        var status = 200
        switch http.url.path {
        case "/v2/user":
            #expect(http.url.host == "api.vercel.com")
            #expect(http.credentialSlot == "primary")
            body = #"{"user":{"defaultTeamId":"team_test"}}"#
        case "/v1/billing/charges":
            #expect(http.url.host == "api.vercel.com")
            #expect(http.credentialSlot == "primary")
            #expect(http.url.query?.contains("teamId=team_test") == true)
            body = """
            {"BilledCost":"42.64","BillingCurrency":"USD","ServiceName":"Compute","Tags":{"ProjectId":"project_a"}}
            {"BilledCost":"99","BillingCurrency":"USD","ServiceName":"Compute","Tags":{"ProjectId":"project_b"}}
            """
        case "/v1/credits":
            #expect(http.url.host == "ai-gateway.vercel.sh")
            #expect(http.credentialSlot == "gateway")
            switch gateway {
            case "missing": throw ExtensionCallError.credentialUnavailable
            case "blocked": throw ExtensionCallError.extensionBlocked
            case "denied": body = "{}"; status = 403
            case "malformed": body = #"{"balance":true}"#
            default: body = #"{"balance":"95.50","total_used":"4.50"}"#
            }
        default: throw ExtensionCallError.invalidRequest
        }
        return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: status, body: Data(body.utf8)))
    }
    if gateway == "blocked" {
        await #expect(throws: ExtensionCallError.extensionBlocked) { try await VercelUsage.fetch(integration, host: host, now: .now) }
    } else {
        let snapshot = try await VercelUsage.fetch(integration, host: host, now: .now)
        #expect(snapshot.metrics.map(\.id) == ["billable|USD", "ai-gateway-balance", "USD|Compute"])
        #expect(snapshot.metrics.first?.value == 42.64)
        #expect(snapshot.metrics[1].value == (gateway == "gateway-only" ? 95.5 : nil))
        #expect(snapshot.metrics[1].detail != nil)
        #expect(snapshot.period == "Last 30 days")
        #expect(!String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("gateway-only"))
    }
}

@Test func teamPickerPaginatesAndSortsDefaultTeamFirst() async throws {
    struct Network: Decodable { let url: URL; let credentialSlot: String }
    let host = RxCodeHost { request in
        let network = try request.decode(Network.self)
        #expect(network.url.host == "api.vercel.com")
        #expect(network.credentialSlot == "primary")
        let body: String
        if network.url.path == "/v2/user" {
            body = #"{"user":{"defaultTeamId":"team_z"}}"#
        } else if network.url.query?.contains("until=101") == true {
            body = #"{"teams":[{"id":"team_a","slug":"a"},{"id":"team_z","slug":"z","name":"Zeta"}]}"#
        } else {
            #expect(network.url.path == "/v2/teams")
            body = #"{"teams":[{"id":"team_a","slug":"a","name":"Alpha"}],"pagination":{"next":101}}"#
        }
        return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 200, body: Data(body.utf8)))
    }
    let choices = try await VercelAccounts.choices(host: host)
    #expect(choices.map(\.id) == ["", "team_z", "team_a"])
    #expect(choices[1].name == "Zeta (z)")
    #expect(choices[2].name == "Alpha (a)")
}
