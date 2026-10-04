import Foundation
import RxAuthSwift
import RxCodeCore
import os

/// Thin wrapper around `RxAuthSwift.OAuthManager` configured for the rxlab
/// identity provider at `https://auth.rxlab.app`. The same `OAuthManager` is
/// shared by every consumer in the app so its `@Observable` state drives
/// SwiftUI views, while ad-hoc HTTP callers can pull the current bearer via
/// `accessToken()`.
@MainActor
final class RxAuthService {

    static let shared = RxAuthService()

    /// rxauth OAuth client registered for the macOS app. Redirect URI must
    /// match `CFBundleURLTypes` in `Info.plist`.
    static let clientID = "client_c54bc9da3f244da5be35588e94f20f5e"
    static let redirectURI = "rxcode://oauth-callback"
    static let issuer = "https://auth.rxlab.app"

    /// Keychain service shared with RxAuthSwift's `KeychainTokenStorage`. The
    /// SDK stores `access_token`, `refresh_token`, and `expires_at` under this
    /// service; we read those items directly for the fast-path token check.
    nonisolated static let defaultKeychainService = "com.rxtech.rxcode.rxauth"

    /// Scopes requested at sign-in. Must stay within the rxlab-auth client's
    /// allowed scopes, which use `read:*` names (the SDK default
    /// `["openid","profile","email"]` triggers `invalid_scope`). `read:email`
    /// lets Autopilot look up the account email via userinfo so notifications
    /// can be delivered.
    nonisolated static let requestedScopes = ["openid", "read:profile", "read:email"]

    /// Set once this launch has signed out a session granted fewer scopes than
    /// `requestedScopes`, so a server that keeps narrowing scopes can't cause
    /// a sign-out loop.
    private var didResetOutdatedScopeSession = false

    let manager: OAuthManager
    let keychainService: String
    private let logger = Logger(subsystem: "com.claudework", category: "RxAuthService")

    /// In-flight token refresh shared by every concurrent `accessToken()`
    /// caller. The rxauth server rotates the refresh token on each use, so two
    /// refreshes firing in parallel would race — one rotates the token out
    /// from under the other, the loser 401s, retries, and refreshes again. On
    /// first sign-in a burst of callers (repo list, installation list, CI
    /// poller, mobile sync) hits the network at once; without coalescing that
    /// burst turns into an endless refresh/retry storm that surfaces as
    /// "infinite loading" while reading repos. One shared task fixes that.
    private var refreshTask: Task<Void, Error>?

    /// In-memory copy of the last access token read from the keychain, with its
    /// expiry. The keychain read is what triggers macOS's "wants to use
    /// confidential information" prompt when the running binary's code signature
    /// no longer matches the item's ACL — and a burst of concurrent
    /// `accessToken()` callers (repo list, installation list, CI poller, mobile
    /// sync) each hit that read, turning one stale-signature prompt into a
    /// storm. Caching here serves every caller from memory, so at most one
    /// keychain read happens per launch until the token nears expiry. A refresh
    /// rewrites the keychain items under the *current* signature, so the seed
    /// read after a refresh no longer prompts either.
    private var cachedToken: (value: String, expiresAt: Date)?

    init(keychainService: String = RxAuthService.defaultKeychainService) {
        self.keychainService = keychainService
        let configuration = RxAuthConfiguration(
            issuer: Self.issuer,
            clientID: Self.clientID,
            redirectURI: Self.redirectURI,
            scopes: Self.requestedScopes,
            passkeyChallengePath: "/api/oauth/passkey/authenticate/options",
            passkeyVerificationPath: "/api/oauth/passkey/authenticate/verify",
            passkeyRegistrationChallengePath: "/api/oauth/passkey/register/options",
            passkeyRegistrationVerificationPath: "/api/oauth/passkey/register/verify",
            passkeyUpgradeChallengePath: "/api/oauth/passkey/upgrade/options",
            passkeyUpgradeVerificationPath: "/api/oauth/passkey/upgrade/verify",
            passkeyAccountCreationOptionsPath: "/api/oauth/passkey/account-creation/options",
            passkeyAccountCreationVerifyPath: "/api/oauth/passkey/account-creation/verify",
            // Must match the `webcredentials:rxlab.app` entitlement and the
            // AASA file served at https://rxlab.app/.well-known/apple-app-site-association.
            passkeyRelyingPartyIdentifier: "rxlab.app",
            keychainServiceName: keychainService
        )
        self.manager = OAuthManager(
            configuration: configuration,
            tokenStorage: AppSupport.isTestProcess ? InMemoryTokenStorage() : nil
        )
    }

    var isAuthenticated: Bool { manager.authState == .authenticated }
    var user: User? { manager.currentUser }

    /// Returns a current bearer token, refreshing first only if the cached
    /// one is missing or near expiry. Returns `nil` when the user is signed
    /// out or refresh failed.
    ///
    /// Pass `forceRefresh: true` to skip the cached-token fast path and always
    /// rotate to a brand-new token. Callers use this after a server `401`: the
    /// keychain `expires_at` can still look fresh while the server has already
    /// rejected the token (rotation, revocation, or clock skew), so reusing the
    /// cached value would just 401 again. Forcing a refresh is what actually
    /// recovers the session instead of surfacing a spurious "Not signed in".
    ///
    /// Note: `OAuthManager.refreshTokenIfNeeded()` refreshes *unconditionally*
    /// despite its name, so we gate it ourselves with the keychain `expires_at`
    /// to avoid a token rotation + userinfo round trip on every autopilot call.
    func accessToken(forceRefresh: Bool = false) async -> String? {
        let token = await resolveAccessToken(forceRefresh: forceRefresh)
        #if DEBUG
        if let token { Self.debugLogToken(token) }
        #endif
        if let token, await resetSessionIfScopesOutdated(token) {
            return nil
        }
        return token
    }

    /// A refresh reuses the scopes of the stored refresh token, so a session
    /// signed in before `requestedScopes` grew never gains the new scopes.
    /// Signs such a session out (once per launch) so the next sign-in
    /// requests them. Returns true when it signed out.
    private func resetSessionIfScopesOutdated(_ token: String) async -> Bool {
        guard !didResetOutdatedScopeSession,
              let granted = Self.grantedScopes(in: token)
        else { return false }
        let missing = Set(Self.requestedScopes).subtracting(granted)
        guard !missing.isEmpty else { return false }
        didResetOutdatedScopeSession = true
        logger.notice("RxAuth session is missing scopes \(missing.sorted().joined(separator: " "), privacy: .public); signing out so the next sign-in grants them")
        await signOut()
        NotificationCenter.default.post(name: .rxAuthSessionExpired, object: nil)
        return true
    }

    /// The space-separated `scope` claim of a JWT access token, or nil when
    /// the token isn't a JWT or has no `scope` claim.
    nonisolated static func grantedScopes(in token: String) -> Set<String>? {
        guard let claims = jwtClaims(token), let scope = claims["scope"] as? String else { return nil }
        return Set(scope.split(separator: " ").map(String.init))
    }

    nonisolated static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = base64URLDecode(parts[1]) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func base64URLDecode(_ segment: Substring) -> Data? {
        var base64 = segment.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    #if DEBUG
    /// Last token printed by `debugLogToken`, so each token is logged once.
    private static var lastLoggedToken: String?

    /// Debug builds only: prints the access token and its decoded JWT header
    /// and claims to the Xcode console (once per token) to diagnose scopes.
    private static func debugLogToken(_ token: String) {
        guard token != lastLoggedToken else { return }
        lastLoggedToken = token
        func decode(_ segment: Substring) -> String {
            guard let data = base64URLDecode(segment) else { return "<not base64>" }
            if let object = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                return String(decoding: pretty, as: UTF8.self)
            }
            return String(decoding: data, as: UTF8.self)
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        print("[RxAuth][DEBUG] access token: \(token)")
        if parts.count == 3 {
            print("[RxAuth][DEBUG] header: \(decode(parts[0]))")
            print("[RxAuth][DEBUG] claims: \(decode(parts[1]))")
        } else {
            print("[RxAuth][DEBUG] token is not a JWT (\(parts.count) segments)")
        }
    }
    #endif

    private func resolveAccessToken(forceRefresh: Bool) async -> String? {
        guard !AppSupport.isTestProcess else { return nil }
        // Fastest path — an in-memory, not-yet-expiring token needs no keychain
        // read at all, so concurrent callers never re-trigger the macOS keychain
        // permission prompt. Skipped on a forced refresh, where the token was
        // just rejected by the server.
        if !forceRefresh, let cached = cachedToken, !Self.isExpiring(cached.expiresAt) {
            return cached.value
        }

        // Next path — a cached-in-keychain, not-yet-expiring token needs no
        // network hop. This is the one read that may prompt (once) when the
        // stored item was written by a build with a different signature; we seed
        // the in-memory cache from it so the next caller skips the keychain.
        if !forceRefresh,
           let token = KeychainBackedTokenReader.readAccessToken(service: keychainService),
           let expiresAt = Self.readExpiry(service: keychainService),
           !Self.isExpiring(expiresAt) {
            cachedToken = (token, expiresAt)
            return token
        }

        do {
            try await refreshSharedToken()
        } catch {
            logger.warning("RxAuth refresh failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return seedCacheFromKeychain()
    }

    /// Read the freshly-refreshed token + expiry from the keychain once and
    /// store them in memory. Called after a successful refresh, which rewrites
    /// the keychain items under the current binary's signature — so this read
    /// matches the ACL and does not prompt.
    private func seedCacheFromKeychain() -> String? {
        guard let token = KeychainBackedTokenReader.readAccessToken(service: keychainService) else {
            cachedToken = nil
            return nil
        }
        cachedToken = (token, Self.readExpiry(service: keychainService) ?? .distantPast)
        return token
    }

    /// Run at most one `refreshTokenIfNeeded()` at a time; concurrent callers
    /// await the same in-flight task instead of each kicking off a competing
    /// (refresh-token-rotating) refresh. All access is `@MainActor`-isolated,
    /// so the check-then-store below is atomic up to the first suspension.
    private func refreshSharedToken() async throws {
        if let existing = refreshTask {
            try await existing.value
            return
        }
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { @MainActor [manager] in
            try await manager.refreshTokenIfNeeded()
        }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1e3
        logger.debug("accessToken: refreshTokenIfNeeded returned in \(ms, privacy: .public)ms")
    }

    /// Read the stored access-token expiry from the keychain, or `nil` when
    /// none is recorded.
    private static func readExpiry(service: String) -> Date? {
        guard
            let timestamp = KeychainHelper.readString(service: service, account: "expires_at"),
            let seconds = Double(timestamp)
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Mirror RxAuthSwift's `KeychainTokenStorage.isTokenExpired()`: treat the
    /// token as expiring within 10 minutes of its stored expiry.
    private static func isExpiring(_ expiresAt: Date) -> Bool {
        expiresAt.timeIntervalSinceNow < 600
    }

    func signIn() async throws {
        try await manager.authenticate()
    }

    func signOut() async {
        cachedToken = nil
        await manager.logout()
    }

    /// Restore a session from the last run if there's one in keychain.
    /// Safe to call multiple times — `checkExistingAuth` is idempotent.
    func restore() async {
        await manager.checkExistingAuth()
    }
}

/// Synchronous access to whatever access token RxAuthSwift currently has in
/// its keychain. RxAuthSwift doesn't expose `tokenStorage` publicly, so we
/// read the same keychain entry it wrote.
enum KeychainBackedTokenReader {
    static func readAccessToken(service: String) -> String? {
        KeychainHelper.readString(service: service, account: "access_token")
    }
}
