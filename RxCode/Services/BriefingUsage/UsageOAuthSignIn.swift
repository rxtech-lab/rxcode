import AppKit
import CryptoKit
import RxCodeCore

/// RxCode's registered public Vercel OAuth app. Vercel only accepts HTTP(S)
/// redirect URLs, so sign-in completes on a fixed loopback port that must match
/// the callback registered for this client.
enum VercelUsageOAuth {
    /// Hidden for now: Vercel's OAuth apps can't read team or billing data while
    /// those API permissions are in closed beta, so Vercel integrations use an
    /// access token (API key) instead. The sign-in flow below is kept intact so
    /// it can be re-enabled by flipping this flag once Vercel grants the scopes.
    static let isEnabled = false
    static let clientID = "cl_CASnRfEiqTkvxiZ4prMJaoZ6Kx6OWC0G"
    static let callbackPort: UInt16 = 47615
    static let configuration = UsageOAuthConfiguration(
        clientID: clientID, callbackURL: "http://localhost:\(callbackPort)/oauth/callback", scopes: "openid offline_access")
}

/// HTTP loopback redirect registered with the user's Cloudflare PKCE client.
enum CloudflareUsageOAuth {
    static let clientID = "b6b76fc6ac489f6e340e0b671104e4d1"
    static let callbackURL = "http://localhost:47616/oauth/callback"
    // These read scopes are registered on RxCode's bundled Cloudflare client.
    static let scopes = "account-analytics.read workers-r2.read zone.read memberships.read"
    private static let legacyScopes = "account-analytics.read workers-r2.read zone.read"

    static func configuration(_ saved: UsageOAuthConfiguration?) -> UsageOAuthConfiguration {
        var config = saved ?? .init()
        if config.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            config.clientID = clientID
        }
        if config.clientID == clientID,
           (config.scopes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || config.scopes == legacyScopes) {
            config.scopes = scopes
        }
        if config.callbackURL.isEmpty || config.callbackURL == "rxcode://usage-oauth" {
            config.callbackURL = callbackURL
        }
        return config
    }

    static func callbackPort(_ value: String) -> UInt16? {
        guard let url = URLComponents(string: value), url.scheme == "http",
              ["localhost", "127.0.0.1"].contains(url.host),
              url.path == "/oauth/callback", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let port = url.port, let port = UInt16(exactly: port), port > 0 else { return nil }
        return port
    }
}

extension UsageIntegration {
    /// Vercel always uses the bundled app; other providers use their saved configuration.
    var resolvedOAuth: UsageOAuthConfiguration? {
        switch pluginID {
        case "vercel": VercelUsageOAuth.configuration
        case "cloudflare": CloudflareUsageOAuth.configuration(oauth)
        default: oauth
        }
    }
}

@MainActor
final class UsageOAuthSignIn {
    func signIn(_ integration: UsageIntegration) async throws {
        if integration.pluginID == "vercel" { return try await signInWithVercel(integration) }
        guard integration.pluginID == "cloudflare", let config = integration.resolvedOAuth,
              !config.clientID.isEmpty else { throw UsagePluginError.invalidConfiguration }
        guard !config.scopes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UsagePluginError.oauth("Enter the permission scopes registered on your Cloudflare OAuth client before signing in.")
        }
        guard let port = CloudflareUsageOAuth.callbackPort(config.callbackURL) else {
            throw UsagePluginError.oauth("Use an HTTP loopback callback such as \(CloudflareUsageOAuth.callbackURL), and register the exact URL in your Cloudflare OAuth client.")
        }
        let receiver = MCPOAuthCallbackServer()
        defer { receiver.stop() }
        _ = try await receiver.start(port: port)
        let (url, state, verifier) = Self.authorizeURL("https://dash.cloudflare.com/oauth2/auth", config: config)
        let result = try await receiver.wait(redirectURI: config.callbackURL, accepts: { callback in
            URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "state" })?.value == state
        }) {
            NSWorkspace.shared.open(url)
        }
        try await complete(integration, config: config, callback: result, state: state, verifier: verifier)
    }

    /// Receives the redirect on a loopback HTTP server and finishes in the default browser.
    private func signInWithVercel(_ integration: UsageIntegration) async throws {
        let config = VercelUsageOAuth.configuration
        let receiver = MCPOAuthCallbackServer()
        defer { receiver.stop() }
        _ = try await receiver.start(port: VercelUsageOAuth.callbackPort)
        let (authorize, state, verifier) = Self.authorizeURL("https://vercel.com/oauth/authorize", config: config)
        // Force the consent page so permissions added to the app after a previous sign-in are granted.
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "prompt", value: "consent")]
        let url = components.url!
        let result = try await receiver.wait(redirectURI: config.callbackURL, accepts: { callback in
            URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "state" })?.value == state
        }) {
            NSWorkspace.shared.open(url)
        }
        try await complete(integration, config: config, callback: result, state: state, verifier: verifier)
    }

    private func complete(_ integration: UsageIntegration, config: UsageOAuthConfiguration, callback: URL,
                          state: String, verifier: String) async throws {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.queryItems?.first(where: { $0.name == "state" })?.value == state else { throw UsagePluginError.invalidResponse }
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            throw UsagePluginError.oauth(description ?? error)
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { throw UsagePluginError.invalidResponse }
        try await UsageOAuthTokens.shared.exchange(integration, fields: ["grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "redirect_uri": config.callbackURL])
    }

    static func authorizeURL(_ base: String, config: UsageOAuthConfiguration) -> (url: URL, state: String, verifier: String) {
        let state = UUID().uuidString
        let verifier = UUID().uuidString + UUID().uuidString
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(string: base)!
        url.queryItems = ["client_id": config.clientID, "redirect_uri": config.callbackURL, "response_type": "code",
                          "state": state, "code_challenge": challenge, "code_challenge_method": "S256", "scope": config.scopes]
            .map { .init(name: $0.key, value: $0.value) }
        return (url.url!, state, verifier)
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
    nonisolated static func hasTokens(_ id: UUID) -> Bool {
        KeychainHelper.read(service: "com.rxlab.RxCode.usage.oauth", account: id.uuidString) != nil
    }
    func delete(_ id: UUID) throws {
        try KeychainHelper.delete(service: "com.rxlab.RxCode.usage.oauth", account: id.uuidString)
    }
    private func request(_ integration: UsageIntegration, fields: [String: String], previousRefresh: String?) async throws -> Tokens {
        guard let config = integration.resolvedOAuth else { throw UsagePluginError.invalidConfiguration }
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
        guard response.statusCode == 200 else {
            let body = try? JSONDecoder().decode([String: String].self, from: data)
            if let message = body?["error_description"] ?? body?["error"] { throw UsagePluginError.oauth(message) }
            throw UsagePluginError.http(response.statusCode)
        }
        var tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard !tokens.access_token.isEmpty else { throw UsagePluginError.invalidResponse }
        tokens.refresh_token = tokens.refresh_token ?? previousRefresh
        tokens.expiresAt = tokens.expires_in.map { Date().addingTimeInterval($0) }
        try KeychainHelper.save(JSONEncoder().encode(tokens), service: "com.rxlab.RxCode.usage.oauth", account: integration.id.uuidString)
        return tokens
    }
}
