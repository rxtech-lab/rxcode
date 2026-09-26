import os
import RxAuthSwift
import RxAuthSwiftUI
import SwiftUI

private let signInLogger = Logger(subsystem: "com.claudework", category: "MobileSignIn")

/// The app's first screen until the user signs in with their rxlab account.
/// Pairing with a Mac is only offered once a session exists.
struct MobileSignInView: View {
    @Environment(MobileCloudState.self) private var cloud

    var body: some View {
        let manager = cloud.auth.manager
        RxSignInView(
            manager: manager,
            appearance: RxSignInAppearance(
                title: "Welcome to RxCode",
                subtitle: "Sign in with your rxlab account to pair with your Mac.",
                accentColor: .accentColor
            ),
            style: .native,
            onAuthSuccess: { [cloud] in
                signInLogger.info("rxauth sign-in succeeded")
                Task { await cloud.refresh() }
            },
            onAuthFailed: { error in
                signInLogger.error("rxauth sign-in failed: \(String(describing: error), privacy: .public)")
            }
        )
        .accessibilityIdentifier("mobile-sign-in")
    }
}

/// Shown while the stored rxlab session is being restored at launch, so a
/// signed-in user never sees the sign-in screen flash by.
struct MobileRestoringSessionView: View {
    var body: some View {
        ProgressView("Restoring session…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("mobile-restoring-session")
    }
}
