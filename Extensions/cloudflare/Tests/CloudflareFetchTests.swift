import Foundation
import RxCodeExtensionSDK
import Testing
@testable import CloudflareUsage

private struct Network: Decodable {
    let url: URL
    let credentialSlot: String
}
private func integration(_ account: String = "stored") throws -> ExtensionUsageIntegration {
    try JSONDecoder().decode(ExtensionUsageIntegration.self, from: Data("""
    {"id":"04907b33-d54b-49f7-b971-be8d2a797165","pluginID":"cloudflare","title":"Billing","account":"\(account)","resource":""}
    """.utf8))
}

@Test(arguments: ["billing", "oauth", "primary", "denied", "pending"])
func cloudflareChoosesBillingSlotBeforeOAuthOrAPIToken(available: String) async throws {
    let integration = try integration()
    let host = RxCodeHost { request in
        if request.operation == .storageGet {
            return try ExtensionResponse(replyingTo: request, value: ["account": "chosen", "configuredAccount": "stored"])
        }
        let network = try request.decode(Network.self)
        #expect(network.url.path == "/client/v4/accounts/chosen/billable-usage")
        #expect(network.url.host == "api.cloudflare.com")
        #expect(network.url.query == nil)
        if available == "denied" || available == "pending" {
            #expect(network.credentialSlot == "billing")
            if available == "pending" { throw ExtensionCallError.permissionPending }
            return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 403, body: Data()))
        }
        if available == "billing" { #expect(network.credentialSlot == "billing") }
        if available == "oauth" { #expect(network.credentialSlot != "primary") }
        guard network.credentialSlot == available else { throw ExtensionCallError.credentialUnavailable }
        let body = Data("""
        {"success":true,"result":[
        {"ServiceName":"Workers Standard","ConsumedQuantity":150000,"ConsumedUnit":"requests","BilledCost":0.75,"BillingCurrency":"USD","CumulatedContractedCost":0.75},
        {"ServiceName":"Workers Standard","ConsumedQuantity":250000,"ConsumedUnit":"requests","BilledCost":1.25,"BillingCurrency":"USD","CumulatedContractedCost":2.0},
        {"ServiceName":"R2 Storage","ConsumedQuantity":2,"ConsumedUnit":"GB-months","BilledCost":0.03,"BillingCurrency":"USD","CumulatedContractedCost":2.03}]}
        """.utf8)
        return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 200, body: body))
    }
    switch available {
    case "denied":
        do {
            _ = try await CloudflareUsage.fetch(integration, host: host, now: .now)
            Issue.record("Expected billing access denial")
        } catch let error as ExtensionUsageFailure {
            #expect(error.message.contains("Billing > Read"))
        }
    case "pending":
        await #expect(throws: ExtensionCallError.permissionPending) {
            try await CloudflareUsage.fetch(integration, host: host, now: .now)
        }
    default:
        let snapshot = try await CloudflareUsage.fetch(integration, host: host, now: .now)
        #expect(snapshot.scope == "chosen")
        #expect(snapshot.period == "Current billing period")
        #expect(snapshot.metrics.first?.id == "billable|USD")
        #expect(abs((snapshot.metrics.first?.value ?? 0) - 2.03) < 0.0001)
        #expect(snapshot.metrics.first { $0.id == "Workers Standard|requests" }?.value == 400000)
        #expect(snapshot.metrics.first { $0.id == "R2 Storage|GB-months" }?.value == 2)
    }
}

@Test func membershipSettingsPersistForOneIntegrationAndRespectHostEdits() async throws {
    let integration = try integration()
    let host = RxCodeHost { request in
        switch request.operation {
        case .storageSet:
            struct Write: Decodable { let key: String; let value: [String: String] }
            let write = try request.decode(Write.self)
            #expect(write.key == "account.\(integration.id)")
            #expect(write.value == ["account": "new", "configuredAccount": "stored"])
            return try ExtensionResponse(replyingTo: request, value: write.value)
        case .storageGet:
            return try ExtensionResponse(replyingTo: request, value: ["account": "new", "configuredAccount": "old"])
        default: throw ExtensionCallError.invalidRequest
        }
    }
    try await ExtensionUsageAccount.select("new", for: integration, host: host)
    #expect(try await ExtensionUsageAccount.selected(for: integration, host: host) == "stored")
}

@Test func membershipPaginationRemovesDuplicatesAndPendingAccounts() async throws {
    let host = RxCodeHost { request in
        let network = try request.decode(Network.self)
        #expect(network.url.path == "/client/v4/memberships")
        #expect(network.credentialSlot == "oauth")
        #expect(network.url.query?.contains("per_page=50") == true)
        func member(_ id: String, _ status: String = "accepted") -> String {
            #"{"status":"\#(status)","account":{"id":"\#(id)","name":"Account \#(id)"}}"#
        }
        let members = network.url.query?.contains("page=2") == true
            ? [member("0"), member("aaaa"), member("bbbb", "pending")] : (0..<50).map { member(String($0)) }
        let body = Data(#"{"success":true,"result":[\#(members.joined(separator: ","))]}"#.utf8)
        return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: 200, body: body))
    }
    let accounts = try await CloudflareAccounts.list(host: host)
    #expect(accounts.count == 51)
    #expect(accounts.contains { $0.id == "aaaa" })
    #expect(!accounts.contains { $0.id == "bbbb" })
    #expect(accounts.map(\.name) == accounts.map(\.name).sorted())
}
