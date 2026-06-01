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

            capabilitiesGrid

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

    // MARK: - Capabilities

    private struct Capability: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let description: String
    }

    private let capabilities: [Capability] = [
        Capability(
            icon: "key.fill",
            title: String(localized: "Manage Secrets"),
            description: String(localized: "Per-project secrets, end-to-end encrypted and easily shared with your team.")
        ),
        Capability(
            icon: "books.vertical.fill",
            title: String(localized: "Manage Docs"),
            description: String(localized: "Index your repositories into a personalized, searchable knowledge base.")
        ),
        Capability(
            icon: "arrow.triangle.2.circlepath",
            title: String(localized: "Detect CI Issues"),
            description: String(localized: "Autopilot watches your CI, spots failures, and opens fix pull requests.")
        ),
        Capability(
            icon: "tag.fill",
            title: String(localized: "Create Releases"),
            description: String(localized: "Cut and publish semantic releases — all from one app.")
        ),
    ]

    private var capabilitiesGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(capabilities) { capability in
                capabilityCard(capability)
            }
        }
    }

    private func capabilityCard(_ capability: Capability) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: capability.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ClaudeTheme.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(capability.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Text(capability.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
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
