import AppKit
import CryptoKit
import Foundation
import Observation
import os

/// RxCode's registered Hugging Face OAuth app (huggingface.co/settings/applications).
/// It is a public client: PKCE, no secret. Sign-in completes on a fixed
/// loopback port, so `callbackURL` must match the app's registered redirect URL.
nonisolated enum HuggingFaceOAuth {
    static let clientID = "1473d348-300d-4581-a775-33cf2743f64c"
    static let callbackPort: UInt16 = 47617
    static let callbackURL = "http://localhost:\(callbackPort)/oauth/callback"
    static let authorizeURL = URL(string: "https://huggingface.co/oauth/authorize")!
    static let tokenURL = URL(string: "https://huggingface.co/oauth/token")!
    static let userInfoURL = URL(string: "https://huggingface.co/oauth/userinfo")!
    static let whoAmIURL = URL(string: "https://huggingface.co/api/whoami-v2")!
    static let tokenSettingsURL = URL(string: "https://huggingface.co/settings/tokens")!
    /// Profile for the account chip, the user's own (including private) repos,
    /// and public gated repos the user was granted access to.
    static let scopes = "openid profile read-repos gated-repos"

    static func authorize(redirectURI: String) -> (url: URL, state: String, verifier: String) {
        let state = UUID().uuidString
        let verifier = UUID().uuidString + UUID().uuidString
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return (components.url!, state, verifier)
    }
}

/// The signed-in Hugging Face account's token, in the Keychain. An actor so
/// the nonisolated Hub client and downloads can read it, and concurrent
/// requests share one refresh.
actor HuggingFaceCredentials {
    static let shared = HuggingFaceCredentials()

    enum Kind: String, Codable, Sendable {
        case oauth
        case accessToken
    }

    struct Tokens: Codable, Sendable {
        var kind: Kind
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    enum CredentialError: LocalizedError {
        case expired
        case oauth(String)
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .expired: "Your Hugging Face session expired. Sign in again."
            case .oauth(let message): message
            case .http(let status): "Hugging Face returned HTTP \(status) while signing in."
            case .malformed: "Hugging Face returned an unexpected sign-in response."
            }
        }
    }

    private static let service = "com.rxlab.RxCode.huggingface"
    private static let account = "default"
    private let logger = Logger(subsystem: "com.rxlab.RxCode", category: "HuggingFaceAuth")
    /// Loaded lazily: a Keychain read per Hub request would be wasteful.
    private var cached: Tokens?
    private var loaded = false
    private var refresh: Task<Tokens, Error>?

    func save(_ tokens: Tokens) throws {
        refresh?.cancel()
        refresh = nil
        try KeychainHelper.save(JSONEncoder().encode(tokens), service: Self.service, account: Self.account)
        cached = tokens
        loaded = true
    }

    func clear() {
        refresh?.cancel()
        refresh = nil
        try? KeychainHelper.delete(service: Self.service, account: Self.account)
        cached = nil
        loaded = true
    }

    /// The token to send, refreshed when it is about to expire or the Hub
    /// rejected it. Nil when signed out.
    func accessToken(rejecting rejected: String? = nil) async throws -> String? {
        guard let tokens = current() else { return nil }
        if let refresh { return try await refresh.value.accessToken }
        let isRejected = rejected != nil && rejected == tokens.accessToken
        let expiring = tokens.expiresAt.map { $0.timeIntervalSinceNow < 60 } ?? false
        guard isRejected || expiring else { return tokens.accessToken }
        // Access tokens pasted by the user don't expire on a schedule; a
        // rejected one has been revoked.
        guard tokens.kind == .oauth, let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            if isRejected { throw CredentialError.expired }
            return tokens.accessToken
        }
        let task = Task {
            try await Self.requestTokens(fields: ["grant_type": "refresh_token", "refresh_token": refreshToken],
                                         previousRefresh: refreshToken)
        }
        refresh = task
        defer { refresh = nil }
        do {
            let renewed = try await task.value
            try save(renewed)
            logger.info("refreshed Hugging Face OAuth token")
            return renewed.accessToken
        } catch {
            logger.warning("Hugging Face token refresh failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func current() -> Tokens? {
        if !loaded {
            loaded = true
            cached = KeychainHelper.read(service: Self.service, account: Self.account)
                .flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) }
        }
        return cached
    }

    /// Exchanges an authorization code or refresh token at the token endpoint.
    static func requestTokens(fields: [String: String], previousRefresh: String? = nil) async throws -> Tokens {
        var request = URLRequest(url: HuggingFaceOAuth.tokenURL, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var values = fields
        values["client_id"] = HuggingFaceOAuth.clientID
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CredentialError.malformed }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard http.statusCode == 200 else {
            if fields["grant_type"] == "refresh_token", body?["error"] as? String == "invalid_grant" {
                throw CredentialError.expired
            }
            if let message = (body?["error_description"] ?? body?["error"]) as? String {
                throw CredentialError.oauth(message)
            }
            throw CredentialError.http(http.statusCode)
        }
        guard let access = body?["access_token"] as? String, !access.isEmpty else { throw CredentialError.malformed }
        return Tokens(
            kind: .oauth,
            accessToken: access,
            refreshToken: (body?["refresh_token"] as? String) ?? previousRefresh,
            expiresAt: (body?["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
        )
    }
}

/// Who is signed in to Hugging Face, for the Local Models sheet. The account
/// summary is kept in user defaults so the chip shows without a Keychain
/// read or network call; the token itself stays in `HuggingFaceCredentials`.
@MainActor @Observable
final class HuggingFaceAccountStore {
    static let shared = HuggingFaceAccountStore()

    struct Account: Codable, Equatable, Sendable {
        let username: String
        let fullName: String?
        let avatarURL: URL?
        let kind: HuggingFaceCredentials.Kind

        var displayName: String { fullName?.isEmpty == false ? fullName! : username }
        var profileURL: URL { HuggingFaceClient.base.appending(path: username) }
    }

    private(set) var account: Account?
    var isSignedIn: Bool { account != nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let credentials: HuggingFaceCredentials
    @ObservationIgnored private var receiver: MCPOAuthCallbackServer?
    private static let defaultsKey = "huggingFace.account"

    init(defaults: UserDefaults = .standard, credentials: HuggingFaceCredentials = .shared) {
        self.defaults = defaults
        self.credentials = credentials
        account = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Account.self, from: $0) }
    }

    /// OAuth authorization code flow with PKCE in the default browser.
    func signInWithBrowser() async throws {
        receiver?.stop()
        let receiver = MCPOAuthCallbackServer()
        self.receiver = receiver
        defer {
            receiver.stop()
            if self.receiver === receiver { self.receiver = nil }
        }
        _ = try await receiver.start(port: HuggingFaceOAuth.callbackPort)
        let redirectURI = HuggingFaceOAuth.callbackURL
        let (url, state, verifier) = HuggingFaceOAuth.authorize(redirectURI: redirectURI)
        let callback = try await receiver.wait(redirectURI: redirectURI, accepts: { callback in
            URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "state" })?.value == state
        }) {
            NSWorkspace.shared.open(url)
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw HuggingFaceCredentials.CredentialError.oauth(
                items.first(where: { $0.name == "error_description" })?.value ?? error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw HuggingFaceCredentials.CredentialError.malformed
        }
        let tokens = try await HuggingFaceCredentials.requestTokens(fields: [
            "grant_type": "authorization_code", "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI,
        ])
        let account = try await Self.fetchAccount(token: tokens.accessToken, kind: .oauth)
        try await credentials.save(tokens)
        setAccount(account)
    }

    /// Signs in with a user access token from huggingface.co/settings/tokens.
    func signIn(accessToken raw: String) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let account = try await Self.fetchAccount(token: token, kind: .accessToken)
        try await credentials.save(.init(kind: .accessToken, accessToken: token))
        setAccount(account)
    }

    /// Cancels a browser sign-in that is waiting for the redirect.
    func cancelSignIn() {
        receiver?.stop()
        receiver = nil
    }

    func signOut() async {
        await credentials.clear()
        setAccount(nil)
    }

    private func setAccount(_ account: Account?) {
        self.account = account
        if let account, let data = try? JSONEncoder().encode(account) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// `whoami-v2` answers for both OAuth and user access tokens.
    nonisolated static func fetchAccount(token: String, kind: HuggingFaceCredentials.Kind) async throws -> Account {
        var request = URLRequest(url: HuggingFaceOAuth.whoAmIURL, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HuggingFaceCredentials.CredentialError.malformed }
        if http.statusCode == 401 {
            throw HuggingFaceCredentials.CredentialError.oauth(
                kind == .accessToken ? "Hugging Face rejected this access token." : "Hugging Face rejected the sign-in.")
        }
        guard http.statusCode == 200, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let username = object["name"] as? String else {
            throw HuggingFaceCredentials.CredentialError.http(http.statusCode)
        }
        let avatar = (object["avatarUrl"] as? String).flatMap { value in
            // Avatars without a host are relative to the Hub.
            value.hasPrefix("/") ? URL(string: "https://huggingface.co\(value)") : URL(string: value)
        }
        return Account(username: username, fullName: object["fullname"] as? String, avatarURL: avatar, kind: kind)
    }
}

/// Drops the Hub token when a request is redirected to another host: Hub
/// file URLs redirect to pre-signed CDN URLs, which reject a second credential
/// and must never receive the user's token.
nonisolated final class HuggingFaceRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = HuggingFaceRedirectGuard()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.strippingCrossHostAuthorization(request, from: task.originalRequest))
    }

    static func strippingCrossHostAuthorization(_ request: URLRequest, from original: URLRequest?) -> URLRequest {
        guard request.url?.host != original?.url?.host else { return request }
        var copy = request
        copy.setValue(nil, forHTTPHeaderField: "Authorization")
        return copy
    }
}
