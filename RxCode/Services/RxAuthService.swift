import Foundation
import RxAuthSwift
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
    static let keychainService = "com.rxtech.rxcode.rxauth"

    let manager: OAuthManager
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

    init() {
        let configuration = RxAuthConfiguration(
            issuer: Self.issuer,
            clientID: Self.clientID,
            redirectURI: Self.redirectURI,
            // The rxlab-auth client only allows `openid`; the SDK default
            // `["openid","profile","email"]` triggers `invalid_scope`.
            scopes: ["openid"],
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
            keychainServiceName: Self.keychainService
        )
        self.manager = OAuthManager(configuration: configuration)
    }

    var isAuthenticated: Bool { manager.authState == .authenticated }
    var user: User? { manager.currentUser }

    /// Returns a current bearer token, refreshing first only if the cached
    /// one is missing or near expiry. Returns `nil` when the user is signed
    /// out or refresh failed.
    ///
    /// Note: `OAuthManager.refreshTokenIfNeeded()` refreshes *unconditionally*
    /// despite its name, so we gate it ourselves with the keychain `expires_at`
    /// to avoid a token rotation + userinfo round trip on every autopilot call.
    func accessToken() async -> String? {
        // Fast path — a cached, not-yet-expiring token needs no network hop.
        if let cached = KeychainBackedTokenReader.readAccessToken(service: Self.keychainService),
           !Self.accessTokenIsExpiring(service: Self.keychainService) {
            return cached
        }

        do {
            try await refreshSharedToken()
        } catch {
            logger.warning("RxAuth refresh failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return KeychainBackedTokenReader.readAccessToken(service: Self.keychainService)
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

    /// Mirror RxAuthSwift's `KeychainTokenStorage.isTokenExpired()`: treat the
    /// token as expiring within 10 minutes of its stored expiry, and as
    /// expired when no expiry is recorded.
    private static func accessTokenIsExpiring(service: String) -> Bool {
        guard
            let timestamp = KeychainHelper.readString(service: service, account: "expires_at"),
            let seconds = Double(timestamp)
        else { return true }
        return Date(timeIntervalSince1970: seconds).timeIntervalSinceNow < 600
    }

    func signIn() async throws {
        try await manager.authenticate()
    }

    func signOut() async {
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
