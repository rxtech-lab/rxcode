import RxAuthSwift
import RxCodeCore
import SwiftUI

struct AutopilotRepoListView: View {
    @Environment(AppState.self) private var appState
    @Environment(WindowState.self) private var windowState
    @State private var showSignInSheet = false
    @State private var searchText = ""
    @State private var cloningRepo: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if appState.isSignedIn {
                repoList
            } else {
                signInPrompt
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("GitHub")
                .font(.headline)

            Spacer()

            if appState.isSignedIn {
                if let user = appState.rxUser {
                    Text(user.name ?? user.email ?? user.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    Task { await appState.loadRepos(refresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "link.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Sign in to rxlab to\nimport GitHub repos")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showSignInSheet = true
            } label: {
                Label("Sign in with rxlab", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showSignInSheet) {
            RxAuthSignInView()
        }
    }

    private var repoList: some View {
        VStack(spacing: 0) {
            TextField("Search repos...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if appState.isLoadingRepos {
                VStack(spacing: 8) {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if appState.repos.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No repos found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(filteredRepos) { repo in
                    repoRow(repo)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func repoRow(_ repo: AutopilotRepo) -> some View {
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

    private var filteredRepos: [AutopilotRepo] {
        if searchText.isEmpty {
            return appState.repos
        }
        return appState.repos.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.fullName.localizedCaseInsensitiveContains(searchText)
        }
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
    AutopilotRepoListView()
        .environment(AppState())
        .frame(width: 260, height: 400)
}
