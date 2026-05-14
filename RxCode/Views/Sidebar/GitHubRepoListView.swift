import SwiftUI
import RxCodeCore

struct GitHubRepoListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showLoginSheet = false
    @State private var searchText = ""
    @State private var cloningRepo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if appState.isLoggedIn {
                repoList
            } else {
                connectPrompt
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("GitHub")
                .font(.headline)

            Spacer()

            if appState.isLoggedIn {
                if let user = appState.gitHubUser {
                    Text("@\(user.login)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await appState.fetchRepos() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
    }

    // MARK: - Connect Prompt

    private var connectPrompt: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "link.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Connect GitHub to\nimport repos instantly")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showLoginSheet = true
            } label: {
                Label("Connect GitHub", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showLoginSheet) {
            GitHubLoginView()
        }
    }

    // MARK: - Repo List

    private var repoList: some View {
        VStack(spacing: 0) {
            // Search
            TextField("Search repos...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if appState.repos.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No repos found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Don't see your org repos?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Configure org access →",
                         destination: URL(string: "https://github.com/settings/connections/applications/\(GitHubService.oauthClientId)")!)
                        .font(.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(filteredRepos) { repo in
                    repoRow(repo)
                }
                .listStyle(.sidebar)

                if !appState.repos.isEmpty {
                    Link("Don't see your org repos? →",
                         destination: URL(string: "https://github.com/settings/connections/applications/\(GitHubService.oauthClientId)")!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private func repoRow(_ repo: GitHubRepo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name)
                    .font(.body)
                    .lineLimit(1)

                Text(repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if cloningRepo == repo.fullName {
                ProgressView()
                    .controlSize(.small)
            } else if isAlreadyAdded(repo) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button {
                    Task { await cloneRepo(repo) }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Add to projects")
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
}

#Preview {
    GitHubRepoListView()
        .environment(AppState())
        .frame(width: 260, height: 400)
}
