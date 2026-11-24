import Foundation
import RxCodeExtensionSDK

enum CloudflareAccounts {
    private struct Membership: Decodable {
        let account: ExtensionUsageAccount
        let status: String
    }
    private struct Page: Decodable {
        let success: Bool
        let result: [Membership]
    }
    static func list(host: RxCodeHost) async throws -> [ExtensionUsageAccount] {
        var accounts: [String: ExtensionUsageAccount] = [:]
        for page in 1...20 {
            try Task.checkCancellation()
            let url = CloudflareUsage.base.appending(component: "memberships").appending(queryItems: [
                .init(name: "page", value: String(page)), .init(name: "per_page", value: "50"), .init(name: "status", value: "accepted")
            ])
            let (response, _) = try await CloudflareUsage.request(URLRequest(url: url), host: host)
            let result = try JSONDecoder().decode(Page.self, from: CloudflareUsage.checkedBody(response))
            guard result.success else { throw ExtensionCallError.invalidRequest }
            for membership in result.result where membership.status == "accepted" && !membership.account.id.isEmpty {
                accounts[membership.account.id] = membership.account
            }
            if result.result.count < 50 {
                return accounts.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
            }
        }
        throw ExtensionUsageFailure("Cloudflare returned more memberships than this integration supports.")
    }
}
