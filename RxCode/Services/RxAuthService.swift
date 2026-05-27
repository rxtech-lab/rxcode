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

    let manager: OAuthManager
    private let logger = Logger(subsystem: "com.claudework", category: "RxAuthService")

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
            keychainServiceName: "com.rxtech.rxcode.rxauth"
        )
        self.manager = OAuthManager(configuration: configuration)
    }

    var isAuthenticated: Bool { manager.authState == .authenticated }
    var user: User? { manager.currentUser }

    /// Returns a current bearer token, refreshing first if it's expired.
    /// Returns `nil` when the user is signed out or refresh failed.
    func accessToken() async -> String? {
        do {
            try await manager.refreshTokenIfNeeded()
        } catch {
            logger.warning("RxAuth refresh failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return KeychainBackedTokenReader.readAccessToken(
            service: "com.rxtech.rxcode.rxauth"
        )
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
