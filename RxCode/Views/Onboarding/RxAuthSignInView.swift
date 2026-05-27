import RxAuthSwift
import RxAuthSwiftUI
import RxCodeCore
import SwiftUI
import os

struct RxAuthSignInView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private static let logger = Logger(subsystem: "com.claudework", category: "RxAuthSignInView")

    var body: some View {
        let manager = appState.rxAuth.manager
        RxSignInView(
            manager: manager,
            appearance: RxSignInAppearance(
                title: "Welcome to RxCode",
                subtitle: "Sign in with rxlab to import GitHub repositories.",
                accentColor: ClaudeTheme.accent
            ),
            onAuthSuccess: { [appState] in
                Self.logger.info("rxauth sign-in succeeded; state=\(String(describing: manager.authState), privacy: .public)")
                Task { @MainActor in
                    appState.onRxAuthSignedIn()
                    dismiss()
                }
            },
            onAuthFailed: { error in
                Self.logger.error("rxauth sign-in failed: \(String(describing: error), privacy: .public) — manager.errorMessage=\(manager.errorMessage ?? "<nil>", privacy: .public)")
            }
        )
        .onAppear {
            Self.logger.info("RxAuthSignInView appeared — issuer=\(RxAuthService.issuer, privacy: .public) clientID=\(RxAuthService.clientID, privacy: .public) redirectURI=\(RxAuthService.redirectURI, privacy: .public) supportsPasskey=\(manager.supportsPasskeyAuthentication) state=\(String(describing: manager.authState), privacy: .public)")
        }
        .onChange(of: manager.isAuthenticating) { _, newValue in
            Self.logger.info("isAuthenticating -> \(newValue) errorMessage=\(manager.errorMessage ?? "<nil>", privacy: .public)")
        }
        .onChange(of: manager.errorMessage) { _, newValue in
            Self.logger.info("manager.errorMessage -> \(newValue ?? "<nil>", privacy: .public)")
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
            .help("Close")
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 620)
    }
}

#Preview {
    RxAuthSignInView()
        .environment(AppState())
}
