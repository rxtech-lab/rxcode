import RxAuthSwift
import RxCodeCore
import SwiftUI

/// "Autopilot" tab in SettingsView. Shows the signed-in rxlab user and lets
/// the user sign in or sign out of the autopilot integration.
struct AutopilotSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var showSignIn = false
    @State private var isSigningOut = false

    @State private var showManageSecrets = false
    @State private var isEnrollingSecrets = false
    @State private var secretsError: String?

    @State private var showManageDocs = false

    @State private var showManageCIUpdates = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                Divider()
                accountSection
                if appState.isSignedIn {
                    Divider()
                    secretsSection
                    Divider()
                    ciUpdatesSection
                    Divider()
                    docsSection
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showSignIn) {
            RxAuthSignInView()
                .environment(appState)
        }
        .sheet(isPresented: $showManageSecrets, onDismiss: {
            Task { await appState.refreshSecretsStatuses() }
        }) {
            SecretsManageSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showManageCIUpdates, onDismiss: {
            Task { await appState.refreshCIStatuses() }
        }) {
            CIUpdateManageSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showManageDocs, onDismiss: {
            Task { await appState.refreshDocsStatuses() }
        }) {
            DocsManageSheet()
                .environment(appState)
        }
        .task { await appState.refreshSecretsEnrollment() }
    }

    // MARK: - Docs Section

    private var docsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Documentation")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("Index your repositories' docs (design docs, API docs, code docs) so agents and ⌘K can search them. Set up CI to upload docs automatically with an upload token.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            secretsCard {
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: ClaudeTheme.size(18)))
                        .foregroundStyle(ClaudeTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Documentation search")
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        Text("Manage docs repositories, view indexed documents, and create CI upload tokens.")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Manage Docs") { showManageDocs = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - CI Auto-Update Section

    private var ciUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CI Auto-Update")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("Keep your repositories' GitHub Actions up to date automatically. Autopilot scans `.github/workflows` on a schedule and opens a PR when actions are outdated.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            secretsCard {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: ClaudeTheme.size(18)))
                        .foregroundStyle(ClaudeTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CI auto-update scan")
                            .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                        Text("Watch repositories, set scan schedules, and review scan history and pull requests.")
                            .font(.system(size: ClaudeTheme.size(11)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Manage") { showManageCIUpdates = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - Secrets Section

    private var secretsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Secrets")
                    .font(.system(size: ClaudeTheme.size(13), weight: .semibold))
                Text("Store .env files end-to-end encrypted with your passkey. Secrets are encrypted on this device and never leave it unencrypted.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch appState.secretsEnrolled {
            case .none:
                secretsCard {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking enrollment…").foregroundStyle(.secondary)
                    }
                }
            case .some(false):
                secretsEnrollCard
            case .some(true):
                secretsManageCard
            }

            if let secretsError {
                Text(secretsError).foregroundStyle(.red).font(.system(size: ClaudeTheme.size(11)))
            }
        }
    }

    private var secretsEnrollCard: some View {
        secretsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Set up encryption")
                    .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                Text("Create your encryption key. You'll authenticate with your passkey; the key is derived from it and used to protect your secrets.")
                    .font(.system(size: ClaudeTheme.size(11)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await enrollSecrets() }
                } label: {
                    if isEnrollingSecrets { ProgressView().controlSize(.small) } else { Text("Enroll with Passkey") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isEnrollingSecrets)
            }
        }
    }

    private var secretsManageCard: some View {
        secretsCard {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: ClaudeTheme.size(18)))
                    .foregroundStyle(ClaudeTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Encryption enabled")
                        .font(.system(size: ClaudeTheme.size(13), weight: .medium))
                    Text("Manage your repositories, environments, and secrets.")
                        .font(.system(size: ClaudeTheme.size(11)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Manage Secrets") { showManageSecrets = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func secretsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            )
    }

    private func enrollSecrets() async {
        isEnrollingSecrets = true
        secretsError = nil
        defer { isEnrollingSecrets = false }
        do {
            try await appState.enrollSecrets()
        } catch {
            secretsError = error.localizedDescription
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
