import SwiftUI
import RxCodeCore

struct GitHubSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @Environment(\.dismiss) private var dismiss
    @State private var showLoginSheet = false
    @State private var searchText = ""
    @State private var cloningRepo: String?
    @State private var selectedTab = 0
    @State private var customRepoURL = ""
    @State private var customRepoName = ""
    @State private var isAddingCustomRepo = false
    @State private var cloningCustomRepo: String?

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Git Repositories")
                    .font(.headline)
                    .foregroundStyle(ClaudeTheme.textPrimary)

                Spacer()

                if selectedTab == 0, appState.isLoggedIn, let user = appState.gitHubUser {
                    Text("@\(user.login)")
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textSecondary)

                    Button {
                        Task { await appState.fetchRepos() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
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

            // Tab picker
            Picker("Source", selection: $selectedTab) {
                Text("GitHub").tag(0)
                Text("Custom").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ClaudeThemeDivider()

            // Content
            if selectedTab == 0 {
                githubContent
            } else {
                customContent
            }
        }
        .frame(width: 480, height: 520)
        .background(ClaudeTheme.background)
        .focusable(false)
        .task {
            if appState.isLoggedIn, appState.repos.isEmpty {
                await appState.fetchRepos()
            }
        }
        .sheet(isPresented: $showLoginSheet) {
            GitHubLoginView()
        }
    }

    // MARK: - GitHub Content

    private var githubContent: some View {
        Group {
            if appState.isLoggedIn {
                repoContent
            } else {
                connectPrompt
            }
        }
    }

    // MARK: - Connect Prompt

    private var connectPrompt: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "link.badge.plus")
                .font(.system(size: ClaudeTheme.size(40)))
                .foregroundStyle(ClaudeTheme.accent)

            Text("Connect GitHub to\nimport repos instantly")
                .font(.body)
                .foregroundStyle(ClaudeTheme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                showLoginSheet = true
            } label: {
                Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(ClaudeAccentButtonStyle())

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Repo Content

    private var repoContent: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ClaudeTheme.textTertiary)
                TextField("Search repos...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(ClaudeTheme.textPrimary)
            }
            .padding(8)
            .background(ClaudeTheme.surfaceSecondary, in: RoundedRectangle(cornerRadius: ClaudeTheme.cornerRadiusSmall))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ClaudeThemeDivider()

            if appState.isFetchingRepos {
                loadingState
            } else if appState.repos.isEmpty {
                emptyState
            } else {
                repoListContent
            }

            ClaudeThemeDivider()

            // Footer
            HStack {
                Link("Don't see your org repos? →",
                     destination: URL(string: "https://github.com/settings/connections/applications/\(GitHubService.oauthClientId)")!)
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Custom Content

    private var customContent: some View {
        VStack(spacing: 0) {
            // Add button
            HStack {
                Button {
                    withAnimation {
                        isAddingCustomRepo = true
                    }
                } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                .buttonStyle(ClaudeAccentButtonStyle())

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            ClaudeThemeDivider()

            if isAddingCustomRepo {
                addCustomRepoForm
            }

            if appState.customRepos.isEmpty, !isAddingCustomRepo {
                customEmptyState
            } else {
                customRepoList
            }
        }
    }

    private var addCustomRepoForm: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Git URL")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                TextField("https://github.com/owner/repo.git or git@github.com:owner/repo.git", text: $customRepoURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Project Name")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textSecondary)
                TextField("my-project", text: $customRepoName)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    withAnimation {
                        isAddingCustomRepo = false
                        customRepoURL = ""
                        customRepoName = ""
                    }
                }
                .buttonStyle(ClaudeSecondaryButtonStyle())

                Spacer()

                Button {
                    Task { await cloneCustomRepo() }
                } label: {
                    if cloningCustomRepo != nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Clone & Add")
                    }
                }
                .buttonStyle(ClaudeAccentButtonStyle())
                .disabled(customRepoURL.isEmpty || customRepoName.isEmpty || cloningCustomRepo != nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var customEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "archivebox")
                .font(.system(size: 32))
                .foregroundStyle(ClaudeTheme.textTertiary)
            Text("No custom repositories")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
            Text("Add a Git repository by URL")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var customRepoList: some View {
        List {
            ForEach(appState.customRepos) { repo in
                HStack(spacing: 10) {
                    Image(systemName: "archivebox.fill")
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.textTertiary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.name)
                            .font(.body)
                            .foregroundStyle(ClaudeTheme.textPrimary)
                            .lineLimit(1)
                        Text(repo.cloneURL)
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    if cloningCustomRepo == repo.name {
                        ProgressView()
                            .controlSize(.small)
                    } else if isCustomRepoAdded(repo) {
                        Label("Added", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.statusSuccess)
                    } else {
                        Button {
                            Task { await cloneCustomRepo(repo) }
                        } label: {
                            Label("Clone", systemImage: "plus.circle")
                                .font(.caption)
                        }
                        .buttonStyle(ClaudeSecondaryButtonStyle())
                    }

                    Button(role: .destructive) {
                        Task { await appState.removeCustomRepo(repo) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.textTertiary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
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
            Text("No repos found")
                .font(.subheadline)
                .foregroundStyle(ClaudeTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var repoListContent: some View {
        List(filteredRepos) { repo in
            repoRow(repo)
        }
        .listStyle(.plain)
    }

    private func repoRow(_ repo: GitHubRepo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                .font(.caption)
                .foregroundStyle(ClaudeTheme.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.body)
                    .foregroundStyle(ClaudeTheme.textPrimary)
                    .lineLimit(1)
                Text(repo.fullName)
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            if cloningRepo == repo.fullName {
                ProgressView()
                    .controlSize(.small)
            } else if isAlreadyAdded(repo) {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.statusSuccess)
            } else {
                Button {
                    Task { await cloneRepo(repo) }
                } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(ClaudeSecondaryButtonStyle())
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private var filteredRepos: [GitHubRepo] {
        if searchText.isEmpty {
            return appState.repos
        }
        return appState.repos.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.fullName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func isAlreadyAdded(_ repo: GitHubRepo) -> Bool {
        appState.projects.contains { $0.gitHubRepo == repo.fullName }
    }

    private func isCustomRepoAdded(_ repo: CustomRepo) -> Bool {
        appState.projects.contains { $0.path.contains(repo.name) }
    }

    private func cloneRepo(_ repo: GitHubRepo) async {
        cloningRepo = repo.fullName
        do {
            try await appState.cloneAndAddProject(repo, in: windowState)
        } catch {
            windowState.errorMessage = "Clone failed: \(error.localizedDescription)"
            windowState.showError = true
        }
        cloningRepo = nil
    }

    private func cloneCustomRepo(_ repo: CustomRepo? = nil) async {
        if let repo {
            cloningCustomRepo = repo.name
            do {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let clonePath = "\(home)/RxCode/\(repo.name)"
                let fm = FileManager.default
                if !fm.fileExists(atPath: "\(home)/RxCode") {
                    try fm.createDirectory(atPath: "\(home)/RxCode", withIntermediateDirectories: true)
                }
                try await appState.cloneCustomRepo(repo, in: windowState)
            } catch {
                windowState.errorMessage = "Clone failed: \(error.localizedDescription)"
                windowState.showError = true
            }
            cloningCustomRepo = nil
        } else {
            cloningCustomRepo = customRepoName
            do {
                try await appState.addCustomRepo(url: customRepoURL, name: customRepoName, in: windowState)
                customRepoURL = ""
                customRepoName = ""
                isAddingCustomRepo = false
            } catch {
                windowState.errorMessage = "Clone failed: \(error.localizedDescription)"
                windowState.showError = true
            }
            cloningCustomRepo = nil
        }
    }
}

#Preview {
    GitHubSheet()
        .environment(AppState())
}
