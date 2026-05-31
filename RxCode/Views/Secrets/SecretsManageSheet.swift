import RxCodeCore
import SwiftUI

// MARK: - Routes

struct SecretsEnvRoute: Hashable {
    let repoIdentifier: String // internal secrets UUID
    let repoFullName: String
    let env: SecretsEnvironment
}

// MARK: - Manage sheet

/// Top-level "Manage Secrets" sheet: lists every accessible repo (current repo
/// pinned on top, server-sorted), drilling into environments and files.
struct SecretsManageSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Optional project context: pins this repo to the top and enables local
    /// `.env` detection when adding secrets.
    var currentRepoFullName: String?
    var currentProjectPath: String?

    @State private var repos: [SecretsManagedRepo] = []
    @State private var search = ""
    @State private var nextCursor: String?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()
    /// Whether we've already drilled into the pinned repo, so re-running
    /// `reload()` (e.g. on search) doesn't fight the user's navigation.
    @State private var didAutoNavigate = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                content
            }
            .navigationTitle("Manage Secrets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SecretsManagedRepo.self) { repo in
                SecretsRepoDetailView(repo: repo, projectPath: projectPath(for: repo), onClose: { dismiss() })
            }
            .navigationDestination(for: SecretsEnvRoute.self) { route in
                SecretsEnvironmentDetailView(route: route, projectPath: pathIfCurrent(route.repoFullName), onClose: { dismiss() })
            }
        }
        .frame(width: 560, height: 560)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        List {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search repositories", text: $search)
                    .textFieldStyle(.plain)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            ForEach(repos) { repo in
                NavigationLink(value: repo) {
                    SecretsRepoRow(repo: repo)
                }
            }
            if hasMore {
                Button {
                    Task { await loadMore() }
                } label: {
                    HStack { Spacer(); Text("Load more"); Spacer() }
                }
                .disabled(isLoading)
            }
            if repos.isEmpty, !isLoading, errorMessage == nil {
                Text("No repositories found.")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if isLoading, repos.isEmpty { ProgressView() }
        }
        .onChange(of: search) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }

    private func projectPath(for repo: SecretsManagedRepo) -> String? {
        pathIfCurrent(repo.fullName)
    }

    private func pathIfCurrent(_ fullName: String) -> String? {
        guard let currentRepoFullName, fullName == currentRepoFullName else { return nil }
        return currentProjectPath
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await appState.secrets.listManagedRepositories(
                currentRepo: currentRepoFullName,
                search: search
            )
            repos = page.items
            nextCursor = page.pagination.nextCursor
            hasMore = page.pagination.hasMore
            autoNavigateToCurrentRepoIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            repos = []
            hasMore = false
        }
    }

    /// When opened from the banner's deep link with a pinned repo, skip the repo
    /// picker entirely and push straight to that repo's environments page.
    private func autoNavigateToCurrentRepoIfNeeded() {
        guard !didAutoNavigate,
              let currentRepoFullName,
              let match = repos.first(where: { $0.fullName == currentRepoFullName })
        else { return }
        didAutoNavigate = true
        path.append(match)
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await appState.secrets.listManagedRepositories(
                currentRepo: currentRepoFullName,
                search: search,
                cursor: cursor
            )
            repos.append(contentsOf: page.items)
            nextCursor = page.pagination.nextCursor
            hasMore = page.pagination.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SecretsRepoRow: View {
    let repo: SecretsManagedRepo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repo.fullName).font(.body)
                    if repo.isCurrent {
                        Text("Current")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }
                if repo.isManaged {
                    Text("\(repo.environmentsCount) env · \(repo.filesCount) secrets")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not yet managed").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
