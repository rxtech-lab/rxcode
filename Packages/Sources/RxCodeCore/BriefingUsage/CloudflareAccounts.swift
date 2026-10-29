import Foundation

public struct CloudflareAccount: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
}

public enum CloudflareAccounts {
    /// Discovers active account memberships using the OAuth memberships.read scope.
    public static func list(token: String, session: URLSession = .shared,
                            baseURL: URL = URL(string: "https://api.cloudflare.com/client/v4")!) async throws -> [CloudflareAccount] {
        struct Membership: Decodable {
            let account: CloudflareAccount
            let status: String
        }
        struct Page: Decodable {
            let success: Bool
            let result: [Membership]
        }
        var accounts: [String: CloudflareAccount] = [:]
        for page in 1...20 {
            try Task.checkCancellation()
            var url = URLComponents(url: baseURL.appendingPathComponent("memberships"), resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "page", value: String(page)), .init(name: "per_page", value: "50"),
                              .init(name: "status", value: "accepted")]
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else {
                if let message = UsageResponseParser.errorMessage(data) {
                    throw UsagePluginError.provider(response.statusCode, message)
                }
                throw UsagePluginError.http(response.statusCode)
            }
            let result = try JSONDecoder().decode(Page.self, from: data)
            guard result.success else { throw UsagePluginError.invalidResponse }
            for membership in result.result where membership.status == "accepted" && !membership.account.id.isEmpty {
                accounts[membership.account.id] = membership.account
            }
            if result.result.count < 50 {
                return accounts.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
            }
        }
        throw UsagePluginError.paginationLimit
    }
}
