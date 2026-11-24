import Foundation
import Testing
@testable import VercelUsage

struct UsageResponseTests {
    @Test func vercelPreservesCurrenciesAndProjectScope() throws {
        let rows = """
        {"BilledCost":"1.25","BillingCurrency":"USD","ServiceName":"Compute","Tags":{"ProjectId":"a"}}
        {"BilledCost":2,"BillingCurrency":"USD","ServiceName":"Compute","Tags":{"ProjectId":"a"}}
        {"BilledCost":9,"BillingCurrency":"EUR","ServiceName":"Compute","Tags":{"ProjectId":"b"}}
        """
        let metrics = try UsageResponseParser.vercel(Data(rows.utf8), project: "a")
        #expect(metrics.count == 2)
        #expect(metrics.first?.id == "billable|USD")
        #expect(metrics.first?.value == 3.25)
        #expect(metrics.first?.unit == "USD")
        let all = try UsageResponseParser.vercel(Data(rows.utf8), project: "")
        #expect(all.count == 4)
        #expect(all.first { $0.id == "billable|EUR" }?.value == 9)
        #expect(all.first { $0.id == "USD|Compute" }?.value == 3.25)
    }
    @Test func vercelScopeUsesTeamIDSlugOrDefault() {
        #expect(VercelAccounts.scope("").isEmpty)
        #expect(VercelAccounts.scope("team_abc") == ["teamId": "team_abc"])
        #expect(VercelAccounts.scope(" my-team ") == ["slug": "my-team"])
    }
    @Test func vercelTeamsAndProviderErrorsParse() throws {
        let page = try UsageResponseParser.vercelTeams(Data(#"{"teams":[{"id":"team_a","slug":"a","name":"Acme"},{"id":"team_b","slug":"b","name":""}],"pagination":{"count":2,"next":1700000000000,"prev":null}}"#.utf8))
        #expect(page.teams.map(\.name) == ["Acme", "b"])
        #expect(page.next == 1700000000000)
        #expect(try UsageResponseParser.vercelDefaultTeam(Data(#"{"user":{"id":"u","defaultTeamId":"team_b"}}"#.utf8)) == "team_b")
        #expect(UsageResponseParser.errorMessage(Data(#"{"error":{"code":"forbidden","message":"Not authorized"}}"#.utf8)) == "Not authorized")
        #expect(UsageResponseParser.errorMessage(Data(#"{"errors":[{"message":"bad token"}]}"#.utf8)) == "bad token")
        #expect(UsageResponseParser.errorMessage(Data("not json".utf8)) == nil)
    }
    @Test func creditsUseBalanceRatherThanLifetimeSpend() throws {
        let metric = try UsageResponseParser.vercelGatewayCredits(Data(#"{"balance":"95.50","total_used":"4.50"}"#.utf8))
        #expect(metric.value == 95.5)
        #expect(metric.unit == "USD")
        #expect(metric.detail?.contains("used to date") == true)
        for json in [#"{"balance":true,"total_used":0}"#, #"{"balance":"NaN","total_used":0}"#,
                     #"{"balance":-1,"total_used":0}"#, #"{"total_used":0}"#] {
            #expect(throws: (any Error).self) { try UsageResponseParser.vercelGatewayCredits(Data(json.utf8)) }
        }
        #expect(try UsageResponseParser.vercel(Data(), project: "").first?.value == nil)
    }
}
