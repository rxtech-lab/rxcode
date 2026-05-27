import RxAuthSwift
import RxCodeCore
import SwiftUI

/// "Autopilot" tab in SettingsView. Shows the signed-in rxlab user and lets
/// the user sign in or sign out of the autopilot integration.
struct AutopilotSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var showSignIn = false
    @State private var isSigningOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                accountSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showSignIn) {
            RxAuthSignInView()
                .environment(appState)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Autopilot")
                .font(.system(size: ClaudeTheme.size(15), weight: .semibold))
            Text("Sign in with rxlab to import GitHub repositories and use autopilot features.")
                .font(.system(size: ClaudeTheme.size(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if appState.isSignedIn {
            signedInCard
        } else {
            signedOutCard
        }
    }

    private var signedInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.rxUser?.name ?? "rxlab account")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    if let email = appState.rxUser?.email {
                        Text(verbatim: email)
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
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
                    }
                }
                .disabled(isSigningOut)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
        }
    }

    private var signedOutCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: ClaudeTheme.size(20)))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not signed in")
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                Text("Connect your rxlab account to enable autopilot.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Sign In") { showSignIn = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
        )
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
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: ClaudeTheme.size(30)))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
    }
}

#Preview {
    AutopilotSettingsTab()
        .environment(AppState())
}
