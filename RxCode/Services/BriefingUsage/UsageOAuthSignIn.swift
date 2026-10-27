import AppKit
import AuthenticationServices
import CryptoKit
import RxCodeCore

@MainActor
final class UsageOAuthSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
    func signIn(_ integration: UsageIntegration) async throws {
        guard let config = integration.oauth, !config.clientID.isEmpty,
              let callback = URL(string: config.callbackURL), callback.scheme == "rxcode",
              callback.host == "usage-oauth", ["vercel", "cloudflare"].contains(integration.pluginID) else {
            throw UsagePluginError.invalidConfiguration
        }
        let state = UUID().uuidString
        let verifier = UUID().uuidString + UUID().uuidString
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let base = integration.pluginID == "vercel" ? "https://vercel.com/oauth/authorize" : "https://dash.cloudflare.com/oauth2/auth"
        var url = URLComponents(string: base)!
        url.queryItems = ["client_id": config.clientID, "redirect_uri": config.callbackURL, "response_type": "code",
                          "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "scope": config.scopes]
            .map { .init(name: $0.key, value: $0.value) }
        let result: URL = try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "rxcode") { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: UsagePluginError.invalidResponse) }
            }
            session = auth
            auth.presentationContextProvider = self
            if !auth.start() { continuation.resume(throwing: UsagePluginError.invalidConfiguration) }
        }
        defer { session = nil }
        guard result.scheme == callback.scheme, result.host == callback.host, result.path == callback.path,
              let components = URLComponents(url: result, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else { throw UsagePluginError.invalidResponse }
        try await UsageOAuthTokens.shared.exchange(integration, fields: ["grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "redirect_uri": config.callbackURL])
    }
}

actor UsageOAuthTokens {
    static let shared = UsageOAuthTokens()
    private struct Tokens: Codable {
        var access_token: String
        var refresh_token: String?
        var expires_in: Double?
        var expiresAt: Date?
    }
    func exchange(_ integration: UsageIntegration, fields: [String: String]) async throws {
        _ = try await request(integration, fields: fields, previousRefresh: nil)
    }
    func accessToken(_ integration: UsageIntegration) async throws -> String? {
        guard let data = KeychainHelper.read(service: "com.rxlab.RxCode.usage.oauth", account: integration.id.uuidString) else { return nil }
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        if let expiry = tokens.expiresAt, expiry.timeIntervalSinceNow < 60 {
            guard let refresh = tokens.refresh_token else { throw UsagePluginError.http(401) }
            return try await request(integration, fields: ["grant_type": "refresh_token", "refresh_token": refresh], previousRefresh: refresh).access_token
        }
        return tokens.access_token
    }
    func delete(_ id: UUID) throws {
        try KeychainHelper.delete(service: "com.rxlab.RxCode.usage.oauth", account: id.uuidString)
    }
    private func request(_ integration: UsageIntegration, fields: [String: String], previousRefresh: String?) async throws -> Tokens {
        guard let config = integration.oauth else { throw UsagePluginError.invalidConfiguration }
        let endpoint = integration.pluginID == "vercel" ? "https://api.vercel.com/login/oauth/token" : "https://dash.cloudflare.com/oauth2/token"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var values = fields; values["client_id"] = config.clientID
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsagePluginError.invalidResponse }
        guard response.statusCode == 200 else { throw UsagePluginError.http(response.statusCode) }
        var tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard !tokens.access_token.isEmpty else { throw UsagePluginError.invalidResponse }
        tokens.refresh_token = tokens.refresh_token ?? previousRefresh
        tokens.expiresAt = tokens.expires_in.map { Date().addingTimeInterval($0) }
        try KeychainHelper.save(JSONEncoder().encode(tokens), service: "com.rxlab.RxCode.usage.oauth", account: integration.id.uuidString)
        return tokens
    }
}
