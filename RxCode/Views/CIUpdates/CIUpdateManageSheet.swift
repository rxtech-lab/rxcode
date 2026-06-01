import RxCodeCore
import SwiftUI

/// Top-level "CI Auto-Update" sheet: lists every repo configured for CI
/// auto-updates (watched repositories), drilling into each repo's schedule,
/// scan history, and pull requests. "Add Repo" registers a new repo to watch.
struct CIUpdateManageSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Optional project context: when opened from the setup banner's deep link,
    /// skip the picker and go straight to this repo (its detail if already
    /// watched, otherwise the add flow preset to it).
    var currentRepoFullName: String?
    var currentProjectPath: String?

    @State private var repos: [WatchedRepo] = []
    @State private var search = ""
    @State private var nextCursor: String?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var path = NavigationPath()
    @State private var showAdd = false
    @State private var presetAddRepo: String?
    /// Whether we've already handled the pinned repo, so re-running `reload()`
    /// doesn't fight the user's navigation.
    @State private var didAutoNavigate = false

    private var visibleRepos: [WatchedRepo] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return repos }
        return repos.filter { $0.repositoryFullName.lowercased().contains(trimmed) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("CI Auto-Update")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { presetAddRepo = nil; showAdd = true } label: {
                            Label("Add Repo", systemImage: "plus")
                        }
                    }
                }
                .navigationDestination(for: WatchedRepo.self) { repo in
                    CIUpdateRepoDetailView(
                        repo: repo,
                        onRemoved: { removed in
                            repos.removeAll { $0.id == removed.id }
                            path = NavigationPath()
                        },
                        onClose: { dismiss() }
                    )
                }
        }
        .frame(width: 580, height: 580)
        .sheet(isPresented: $showAdd, onDismiss: { Task { await reload() } }) {
            CIAddWatchedRepoSheet(
                existingRepoFullNames: Set(repos.map { $0.repositoryFullName.lowercased() }),
                presetRepoFullName: presetAddRepo
            ) { _ in }
            .environment(appState)
        }
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
            ForEach(visibleRepos) { repo in
                NavigationLink(value: repo) {
                    CIWatchedRepoRow(repo: repo)
                }
            }
            if hasMore, search.isEmpty {
                Button {
                    Task { await loadMore() }
                } label: {
                    HStack { Spacer(); Text("Load more"); Spacer() }
                }
                .disabled(isLoading)
            }
            if visibleRepos.isEmpty, !isLoading, errorMessage == nil {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No repositories are watched for CI auto-updates yet.")
                        .foregroundStyle(.secondary)
                    Button { presetAddRepo = nil; showAdd = true } label: {
                        Label("Add Repository", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .overlay {
            if isLoading, repos.isEmpty { ProgressView() }
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await appState.ciUpdates.listWatchedRepositories()
            repos = page.repositories
            nextCursor = page.nextCursor
            hasMore = page.hasMore
            autoHandleCurrentRepoIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            repos = []
            hasMore = false
        }
    }

    /// When opened from the banner's deep link, skip the picker: drill straight
    /// into the pinned repo if it's already watched, otherwise open the add flow
    /// preset to that repo.
    private func autoHandleCurrentRepoIfNeeded() {
        guard !didAutoNavigate, let currentRepoFullName else { return }
        didAutoNavigate = true
        if let match = repos.first(where: { $0.repositoryFullName.lowercased() == currentRepoFullName.lowercased() }) {
            path.append(match)
        } else {
            presetAddRepo = currentRepoFullName
            showAdd = true
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await appState.ciUpdates.listWatchedRepositories(cursor: cursor)
            repos.append(contentsOf: page.repositories)
            nextCursor = page.nextCursor
            hasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CIWatchedRepoRow: View {
    let repo: WatchedRepo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.repositoryFullName).font(.body)
                HStack(spacing: 6) {
                    Text(repo.scanFrequency.displayName)
                    Text("·")
                    if let date = repo.lastScannedDate {
                        Text("Scanned \(date.formatted(.relative(presentation: .named)))")
                    } else {
                        Text("Never scanned")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
