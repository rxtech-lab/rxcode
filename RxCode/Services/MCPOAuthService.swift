import Foundation
import CryptoKit
import Security
import RxCodeCore

/// Credentials are keyed by the full resource URL, never by a display name.
actor MCPOAuthService {
    static let shared = MCPOAuthService()
    static let redirectURI = "rxcode://mcp/oauth/callback"

    struct Credential: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        let clientID: String
        let tokenEndpoint: URL
        let resource: String
    }

    struct Authorization: Sendable {
        let url: URL
        let state: String
        let verifier: String
        let clientID: String
        let tokenEndpoint: URL
        let resource: String
        var redirectURI: String = MCPOAuthService.redirectURI
    }

    enum AuthError: LocalizedError {
        case invalid(String)
        case denied
        case authorizationFailed
        var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            case .denied: "The authorization server declined sign-in."
            case .authorizationFailed: "The authorization server returned an OAuth error."
            }
        }
    }

    private var refreshes: [String: Task<Credential, Error>] = [:]
    private let session: URLSession

    init(session: URLSession = MCPOAuthHTTP.session) { self.session = session }

    private let service = "com.rxlab.RxCode.mcp.oauth"

    func begin(resource: URL, clientID: String?, redirectURI: String = MCPOAuthService.redirectURI) async throws -> Authorization {
        try Self.validate(resource)
        // Discover from the challenge first, then the path-aware RFC 9728 URL.
        var request = URLRequest(url: resource)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"RxCode","version":"1"}}}"#.utf8)
        let (_, response) = try await session.data(for: request)
        let challenge = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        var metadataURLs: [URL] = []
        if let value = Self.challengeParameter("resource_metadata", in: challenge) {
            guard let url = URL(string: value) else { throw AuthError.invalid("Invalid resource metadata URL.") }
            metadataURLs = [url]
        } else {
            var components = URLComponents(url: resource, resolvingAgainstBaseURL: false)!
            components.path = "/.well-known/oauth-protected-resource" + (resource.path == "/" ? "" : resource.path)
            components.query = nil
            metadataURLs.append(components.url!)
            components.path = "/.well-known/oauth-protected-resource"
            if !metadataURLs.contains(components.url!) { metadataURLs.append(components.url!) }
        }
        let protectedResource = try await firstMetadata(metadataURLs)
        guard protectedResource["resource"]?.stringValue == resource.absoluteString,
              let issuerString = protectedResource["authorization_servers"]?.arrayValue?.first?.stringValue,
              let issuer = URL(string: issuerString) else {
            throw AuthError.invalid("The server did not advertise matching OAuth resource metadata.")
        }
        try Self.validate(issuer)
        var discovery = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        discovery.path = "/.well-known/oauth-authorization-server" + (issuer.path == "/" ? "" : issuer.path)
        discovery.query = nil
        var authorizationMetadataURLs = [discovery.url!]
        discovery.path = "/.well-known/openid-configuration" + (issuer.path == "/" ? "" : issuer.path)
        authorizationMetadataURLs.append(discovery.url!)
        if !issuer.path.isEmpty, issuer.path != "/" {
            discovery.path = issuer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            discovery.path = "/" + discovery.path + "/.well-known/openid-configuration"
            authorizationMetadataURLs.append(discovery.url!)
        }
        let metadata = try await firstMetadata(authorizationMetadataURLs)
        guard metadata["issuer"]?.stringValue == issuerString,
              metadata["code_challenge_methods_supported"]?.arrayValue?.contains(.string("S256")) == true,
              let authorizationString = metadata["authorization_endpoint"]?.stringValue,
              let authorizationEndpoint = URL(string: authorizationString),
              let tokenString = metadata["token_endpoint"]?.stringValue,
              let tokenEndpoint = URL(string: tokenString) else {
            throw AuthError.invalid("The authorization server must advertise PKCE S256 and valid OAuth endpoints.")
        }
        try Self.validate(authorizationEndpoint)
        try Self.validate(tokenEndpoint)
        var resolvedClientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if resolvedClientID.isEmpty {
            guard let registrationString = metadata["registration_endpoint"]?.stringValue,
                  let registration = URL(string: registrationString) else {
                throw AuthError.invalid("This server requires a registered OAuth client ID. Enter it in the sign-in sheet.")
            }
            let registered = try await json(url: registration, body: .object([
                "client_name": .string("RxCode"),
                "redirect_uris": .array([.string(redirectURI)]),
                "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
                "response_types": .array([.string("code")]),
                "token_endpoint_auth_method": .string("none")
            ]))
            resolvedClientID = registered["client_id"]?.stringValue ?? ""
            guard !resolvedClientID.isEmpty else { throw AuthError.invalid("OAuth registration returned no client ID.") }
        }
        let verifier = Self.randomString()
        let state = Self.randomString()
        let challengeValue = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: resolvedClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challengeValue),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource.absoluteString)
        ]
        let scope = Self.challengeParameter("scope", in: challenge)
            ?? protectedResource["scopes_supported"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ")
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        components.queryItems = (components.queryItems ?? []) + items
        return Authorization(url: components.url!, state: state, verifier: verifier,
                             clientID: resolvedClientID, tokenEndpoint: tokenEndpoint, resource: resource.absoluteString, redirectURI: redirectURI)
    }

    func complete(_ authorization: Authorization, callback: URL) async throws {
        let code = try Self.callbackCode(authorization, callback: callback)
        let token = try await exchange(endpoint: authorization.tokenEndpoint, fields: [
            "grant_type": "authorization_code", "code": code, "code_verifier": authorization.verifier,
            "redirect_uri": authorization.redirectURI, "client_id": authorization.clientID, "resource": authorization.resource
        ])
        let credential = try credential(from: token, clientID: authorization.clientID,
                                        endpoint: authorization.tokenEndpoint, resource: authorization.resource)
        try Task.checkCancellation()
        try store(credential)
    }

    nonisolated static func callbackCode(_ authorization: Authorization, callback: URL) throws -> String {
        guard let expected = URL(string: authorization.redirectURI),
              callback.scheme == expected.scheme, callback.host == expected.host,
              callback.port == expected.port, callback.path == expected.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil,
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == authorization.state else {
            throw AuthError.invalid("OAuth callback was cancelled or failed state validation.")
        }
        if let error = items.first(where: { $0.name == "error" }) {
            // Do not display untrusted provider descriptions or retry explicit denial.
            if error.value == "access_denied" { throw AuthError.denied }
            throw AuthError.authorizationFailed
        }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AuthError.invalid("OAuth callback did not include an authorization code.")
        }
        return code
    }

    func accessToken(for resource: String) async throws -> String? {
        guard var saved = try read(resource) else { return nil }
        if let expiry = saved.expiresAt, expiry <= Date().addingTimeInterval(60) {
            guard let refresh = saved.refreshToken else { throw AuthError.invalid("Sign in again to renew MCP access.") }
            if let pending = refreshes[resource] { return try await pending.value.accessToken }
            let previous = saved
            let pending = Task {
                let token = try await exchange(endpoint: previous.tokenEndpoint, fields: [
                    "grant_type": "refresh_token", "refresh_token": refresh,
                    "client_id": previous.clientID, "resource": resource
                ])
                var renewed = try credential(from: token, clientID: previous.clientID, endpoint: previous.tokenEndpoint, resource: resource)
                renewed.refreshToken = renewed.refreshToken ?? previous.refreshToken
                try Task.checkCancellation()
                try store(renewed)
                return renewed
            }
            refreshes[resource] = pending
            defer { refreshes.removeValue(forKey: resource) }
            saved = try await pending.value
        }
        return saved.accessToken
    }

    func signOut(resource: String) throws {
        refreshes.removeValue(forKey: resource)?.cancel()
        let status = SecItemDelete(query(resource) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.invalid("Could not remove MCP credentials from Keychain.")
        }
    }

    private func credential(from json: JSONValue, clientID: String, endpoint: URL, resource: String) throws -> Credential {
        guard let access = json["access_token"]?.stringValue, !access.isEmpty,
              json["token_type"]?.stringValue?.lowercased() == "bearer" else {
            throw AuthError.invalid("OAuth server returned no Bearer access token.")
        }
        let expires = json["expires_in"]?.numberValue.map { Date().addingTimeInterval($0) }
        return Credential(accessToken: access, refreshToken: json["refresh_token"]?.stringValue,
                          expiresAt: expires, clientID: clientID, tokenEndpoint: endpoint, resource: resource)
    }

    private func exchange(endpoint: URL, fields: [String: String]) async throws -> JSONValue {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        return try await send(request)
    }

    private func firstMetadata(_ urls: [URL]) async throws -> JSONValue {
        for url in urls {
            try Task.checkCancellation()
            do { return try await json(url: url) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw AuthError.invalid("Could not discover OAuth metadata for this server.")
    }

    private nonisolated static func challengeParameter(_ name: String, in header: String) -> String? {
        let pattern = #"(?:^|[\s,])"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return String(header[range])
    }

    private func json(url: URL, body: JSONValue? = nil) async throws -> JSONValue {
        try Self.validate(url)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        try Self.validate(request.url!)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.invalid("OAuth request failed. Check the server configuration and try signing in again.")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    nonisolated static func validate(_ url: URL) throws {
        guard url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(url.host ?? "")) else {
            throw AuthError.invalid("OAuth endpoints must use HTTPS (HTTP is allowed only for loopback servers).")
        }
    }

    private func query(_ resource: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: resource]
    }

    private func read(_ resource: String) throws -> Credential? {
        var fields = query(resource)
        fields[kSecReturnData as String] = true
        fields[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(fields as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AuthError.invalid("Could not read MCP credentials from Keychain.")
        }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    private func store(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        let fields = query(credential.resource)
        let status = SecItemUpdate(fields as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = fields
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(addition as CFDictionary, nil) == errSecSuccess else {
                throw AuthError.invalid("Could not save MCP credentials to Keychain.")
            }
        } else if status != errSecSuccess {
            throw AuthError.invalid("Could not update MCP credentials in Keychain.")
        }
    }

    private nonisolated static func randomString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64URLEncoded
    }
}

private extension Data {
    nonisolated var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Never forward OAuth codes, refresh tokens, or registration bodies through redirects.
nonisolated final class MCPOAuthHTTP: NSObject, URLSessionTaskDelegate, Sendable {
    static let session = URLSession(configuration: .ephemeral, delegate: MCPOAuthHTTP(), delegateQueue: nil)

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
