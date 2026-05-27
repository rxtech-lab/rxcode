import RxAuthSwift
import RxCodeCore
import SwiftUI

struct AutopilotRepoSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss

    @State private var showSignInSheet = false
    @State private var searchText = ""
    @State private var cloningRepo: String?
    @State private var hoveredRepoId: Int?
    /// Debounce task for server-side search. Cancelled and replaced on every
    /// keystroke so we only fire one `loadRepos(search:)` after the user pauses.
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            titleBar

            ClaudeThemeDivider()

            if appState.isSignedIn {
                repoContent
            } else {
                signInPrompt
            }
        }
        .frame(width: 620, height: 620)
        .background(ClaudeTheme.background)
        .focusable(false)
        .task {
            if appState.isSignedIn {
                if appState.hasGitHubAppInstalled == nil {
                    await appState.checkInstallation()
                }
                if appState.hasGitHubAppInstalled == true, appState.repos.isEmpty {
                    await appState.loadRepos()
                }
            }
        }
        .sheet(isPresented: $showSignInSheet) {
            RxAuthSignInView()
                .environment(appState)
        }
        .onChange(of: appState.isSignedIn) { _, signedIn in
            // Dismiss the sign-in prompt as soon as the shared
            // `OAuthManager` flips to authenticated — covers the case where
            // sign-in completes from a different surface (e.g. settings).
            if signedIn {
                showSignInSheet = false
            }
        }
        .onChange(of: searchText) { _, newValue in
            // Debounce keystrokes — fire one server query after the user
            // pauses typing. Empty string reloads the unfiltered first page.
            searchTask?.cancel()
            searchTask = Task { [newValue] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                await appState.loadRepos(search: newValue)
            }
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private var titleBar: some View {
        HStack {
            Text("Import Repository")
                .font(.headline)
                .foregroundStyle(ClaudeTheme.textPrimary)

            Spacer()

            if appState.isSignedIn, let user = appState.rxUser {
                Text(user.name ?? user.email ?? user.id)
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .lineLimit(1)

                // Always-available install entry point — users with one
                // installation often need to add another (e.g. an org they
                // don't yet own a repo from).
                Button {
                    Task { await appState.openInstallGitHubApp() }
                } label: {
                    if appState.isOpeningInstallUrl {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "app.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(appState.isOpeningInstallUrl)
                .help("Install GitHub App on another account")

                Button {
                    Task { await appState.refreshInstallationAndRepos() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textSecondary)
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .disabled(appState.isCheckingInstall || appState.isLoadingRepos)
                .help("Refresh")
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(ClaudeTheme.textTertiary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var signInPrompt: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "link.badge.plus")
                .font(.system(size: ClaudeTheme.size(40)))
                .foregroundStyle(ClaudeTheme.accent)

            Text("Sign in to rxlab to\nimport your GitHub repos")
                .font(.body)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                showSignInSheet = true
            } label: {
                Label("Sign in with rxlab", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(ClaudeAccentButtonStyle())

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var repoContent: some View {
        // The precheck runs in `.task`; until it lands, show the same loading
        // spinner so we don't flash an install CTA at users who already have
        // installations.
        if appState.hasGitHubAppInstalled == nil || appState.isCheckingInstall {
            loadingState
        } else if appState.hasGitHubAppInstalled == false {
            installGitHubAppState
        } else {
            VStack(spacing: 0) {
                searchBar

                ClaudeThemeDivider()

                if appState.isLoadingRepos {
                    loadingState
                } else if appState.repos.isEmpty {
                    if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        emptyState
                    } else {
                        noMatchesState
                    }
                } else {
                    repoListContent
                    repoListFooter
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ClaudeTheme.textTertiary)
            TextField("Search repos...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ClaudeTheme.textPrimary)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                }
                .buttonStyle(.borderless)
                .focusable(false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text("Loading repos...")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No repos found")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var noMatchesState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No repos match \u{201C}\(searchText)\u{201D}")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Shown when the precheck reports zero GitHub App installations for the
    /// signed-in user. Primary action opens the GitHub install URL in the
    /// default browser; secondary Refresh re-runs the precheck so the sheet
    /// can flip to the repo list once the install completes.
    private var installGitHubAppState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "app.badge.checkmark")
                .font(.system(size: ClaudeTheme.size(40)))
                .foregroundStyle(ClaudeTheme.accent)

            VStack(spacing: 6) {
                Text("Install the GitHub App")
                    .font(.headline)
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Text("RxCode needs the GitHub App to see your repositories. Install it for the account or organizations you want to import from.")
                    .font(.subheadline)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await appState.openInstallGitHubApp() }
                } label: {
                    if appState.isOpeningInstallUrl {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Install GitHub App", systemImage: "arrow.up.right.square")
                    }
                }
                .buttonStyle(ClaudeAccentButtonStyle())
                .disabled(appState.isOpeningInstallUrl)

                Button {
                    Task { await appState.refreshInstallationAndRepos() }
                } label: {
                    if appState.isCheckingInstall {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(ClaudeSecondaryButtonStyle())
                .disabled(appState.isCheckingInstall)
            }

            Text("Finished installing? Tap Refresh.")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var repoListContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(appState.repos.enumerated()), id: \.element.id) { index, repo in
                    if index > 0 {
                        ClaudeThemeDivider()
                            .padding(.leading, 16)
                    }
                    repoRow(repo)
                        .onAppear {
                            // Infinite scroll: when the row a couple before the
                            // end becomes visible, page the next batch from the
                            // server. `loadMoreRepos()` is itself a no-op when
                            // a load is in flight or `hasMore` is false, so
                            // firing eagerly is safe.
                            if index >= appState.repos.count - 5 {
                                Task { await appState.loadMoreRepos() }
                            }
                        }
                }

                if appState.isLoadingMoreRepos {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading more...")
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ClaudeTheme.background)
    }

    private var repoListFooter: some View {
        HStack {
            Text(repoFooterLabel)
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ClaudeTheme.surfaceSecondary.opacity(0.4))
        .overlay(alignment: .top) { ClaudeThemeDivider() }
    }

    /// "12 repos" while there are more pages to load, "12 of 12 repos" once
    /// we've reached the end — gives the user a visible "done" signal so
    /// they don't keep scrolling waiting for more.
    private var repoFooterLabel: String {
        let count = appState.repos.count
        let noun = count == 1 ? "repo" : "repos"
        if appState.repoHasMoreRepos {
            return "\(count) \(noun)"
        }
        return "\(count) of \(count) \(noun)"
    }

    private func repoRow(_ repo: AutopilotRepo) -> some View {
        let added = isAlreadyAdded(repo)
        let cloning = cloningRepo == repo.fullName
        let hovered = hoveredRepoId == repo.id

        return HStack(alignment: .top, spacing: 12) {
            // Owner avatar / fallback icon — keeps each row visually anchored
            // even when names are very similar across orgs.
            ownerAvatar(for: repo)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(repo.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.textPrimary)
                        .lineLimit(1)

                    visibilityBadge(for: repo)

                    Text(repo.owner)
                        .font(.system(size: 11))
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .lineLimit(1)
                }

                if let description = repo.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(ClaudeTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let updated = relativeUpdated(repo.updatedAt) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text("Updated \(updated)")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(ClaudeTheme.textTertiary)
                }
            }

            Spacer(minLength: 8)

            rowTrailing(repo: repo, added: added, cloning: cloning, hovered: hovered)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            hovered && !added
                ? ClaudeTheme.surfaceSecondary.opacity(0.5)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRepoId = hovering ? repo.id : (hoveredRepoId == repo.id ? nil : hoveredRepoId)
        }
        .onTapGesture {
            guard !added, !cloning else { return }
            Task { await cloneRepo(repo) }
        }
    }

    @ViewBuilder
    private func ownerAvatar(for repo: AutopilotRepo) -> some View {
        let installation = appState.installations.first { $0.accountLogin.caseInsensitiveCompare(repo.owner) == .orderedSame }
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(ClaudeTheme.surfaceSecondary)
                .frame(width: 28, height: 28)

            if let urlString = installation?.accountAvatarUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Image(systemName: "person.crop.square.fill")
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(String(repo.owner.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.textSecondary)
            }
        }
    }

    private func visibilityBadge(for repo: AutopilotRepo) -> some View {
        HStack(spacing: 3) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                .font(.system(size: 9, weight: .semibold))
            Text(repo.isPrivate ? "Private" : "Public")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(ClaudeTheme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(ClaudeTheme.surfaceSecondary)
        )
    }

    @ViewBuilder
    private func rowTrailing(repo: AutopilotRepo, added: Bool, cloning: Bool, hovered: Bool) -> some View {
        if cloning {
            ProgressView()
                .controlSize(.small)
        } else if added {
            Label("Added", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ClaudeTheme.statusSuccess)
                .labelStyle(.titleAndIcon)
        } else {
            Button {
                Task { await cloneRepo(repo) }
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(ClaudeSecondaryButtonStyle())
            .opacity(hovered ? 1.0 : 0.75)
        }
    }

    private func relativeUpdated(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        let date = isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func isAlreadyAdded(_ repo: AutopilotRepo) -> Bool {
        appState.projects.contains { $0.gitHubRepo == repo.fullName }
    }

    private func cloneRepo(_ repo: AutopilotRepo) async {
        cloningRepo = repo.fullName
        do {
            try await appState.cloneAndAddProject(repo, in: windowState)
        } catch {
            windowState.errorMessage = "Clone failed: \(error.localizedDescription)"
            windowState.showError = true
        }
        cloningRepo = nil
    }
}

#Preview {
    AutopilotRepoSheet()
        .environment(AppState())
        .environment(WindowState())
}
