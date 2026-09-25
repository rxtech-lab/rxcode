import AppKit
import AuthenticationServices
import RxCodeCore

/// Runs the relay's Notion OAuth page in the system web authentication
/// session and returns the `rxcode://notion-callback` URL it ends on.
///
/// Not ephemeral, so a browser that is already signed in to Notion goes
/// straight to the consent screen.
@MainActor
final class NotionWebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .customScheme(NotionOAuthSession.callbackScheme)
            ) { callbackURL, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    continuation.resume(throwing: cancelled ? NotionOAuthError.cancelled : error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: NotionOAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            // The completion handler isn't called when the session can't start.
            if !session.start() {
                continuation.resume(throwing: NotionOAuthError.invalidCallback)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }
}
