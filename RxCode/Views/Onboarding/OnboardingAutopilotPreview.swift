import RxAuthSwift
import RxCodeCore
import SwiftUI

/// Onboarding slide visual that lets the user sign in to their Autopilot
/// (rxlab) account. Mirrors the styling of the other onboarding previews and
/// reuses `RxAuthSignInView` for the actual OAuth/passkey flow.
struct AutopilotSignInPreview: View {
    let appState: AppState
    @State private var showSignIn = false
    @State private var isSigningOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.shield.checkmark.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
                Text("Autopilot Account")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }

            Text("Sign in with rxlab to import GitHub repositories, sync encrypted secrets, and use autopilot features. You can skip this and sign in later from Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))

            if appState.isSignedIn {
                signedInCard
            } else {
                signedOutCard
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .sheet(isPresented: $showSignIn) {
            RxAuthSignInView()
                .environment(appState)
        }
    }

    private var signedInCard: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.rxUser?.name ?? "rxlab account")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let email = appState.rxUser?.email {
                    Text(verbatim: email)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(ClaudeTheme.statusSuccess)
                Text("Signed in")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ClaudeTheme.statusSuccess)
            }
            Button {
                Task {
                    isSigningOut = true
                    defer { isSigningOut = false }
                    await appState.signOutRxAuth()
                }
            } label: {
                if isSigningOut {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign Out")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .buttonStyle(.plain)
            .disabled(isSigningOut)
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var signedOutCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not signed in")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Connect your rxlab account to enable autopilot.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 8)
            Button {
                showSignIn = true
            } label: {
                Text("Sign In")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 88, height: 30)
                    .foregroundStyle(.white)
                    .background(ClaudeTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var avatar: some View {
        if let urlString = appState.rxUser?.image, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    avatarPlaceholder
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: 34))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 40, height: 40)
    }
}
