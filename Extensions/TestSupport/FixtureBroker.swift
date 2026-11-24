import Foundation
import RxCodeExtensionSDK

/// Test-only transport for the repository's Vercel and Cloudflare HTTP simulations.
public enum FixtureBroker {
    public static func integration(pluginID: String, title: String, account: String, resource: String = "",
                                   projectID: UUID? = nil) throws -> ExtensionUsageIntegration {
        var fields = ["id": UUID().uuidString, "pluginID": pluginID, "title": title, "account": account, "resource": resource]
        fields["projectID"] = projectID?.uuidString
        return try JSONDecoder().decode(ExtensionUsageIntegration.self, from: JSONEncoder().encode(fields))
    }

    public static func host(baseURL: URL, slots: [String: String]) -> RxCodeHost {
        struct Network: Decodable {
            let url: URL
            let method: String
            let headers: [String: String]
            let body: Data?
            let credentialSlot: String
        }
        return RxCodeHost { request in
            if request.operation == .storageGet { return try ExtensionResponse(replyingTo: request, value: String?.none) }
            guard request.operation == .netFetch else { throw ExtensionCallError.invalidRequest }
            let input = try request.decode(Network.self)
            guard let token = slots[input.credentialSlot], !token.isEmpty else { throw ExtensionCallError.credentialUnavailable }
            let path: String
            switch input.url.host {
            case "api.cloudflare.com" where input.url.path == "/client/v4/graphql": path = "" // fixture URL includes GraphQL endpoint
            case "api.cloudflare.com" where input.url.path.hasPrefix("/client/v4/"): path = String(input.url.path.dropFirst("/client/v4/".count))
            case "api.vercel.com", "ai-gateway.vercel.sh": path = String(input.url.path.dropFirst())
            default: throw ExtensionCallError.invalidRequest
            }
            let target = path.isEmpty ? baseURL : baseURL.appending(path: path)
            var parts = URLComponents(url: target, resolvingAgainstBaseURL: false)
            parts?.percentEncodedQuery = URLComponents(url: input.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
            guard let url = parts?.url else { throw ExtensionCallError.invalidRequest }
            var network = URLRequest(url: url)
            network.httpMethod = input.method
            network.allHTTPHeaderFields = input.headers
            network.httpBody = input.body
            network.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (body, response) = try await URLSession.shared.data(for: network)
            guard let http = response as? HTTPURLResponse else { throw ExtensionCallError.invalidRequest }
            return try ExtensionResponse(replyingTo: request, value: ExtensionHTTPResponse(status: http.statusCode, body: body))
        }
    }
}
