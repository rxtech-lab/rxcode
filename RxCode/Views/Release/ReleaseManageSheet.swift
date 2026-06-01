import RxCodeCore
import SwiftUI

/// Top-level "Manage Releases" sheet: lists every release-managed repository and
/// drills into a repo to select its release workflow, install the RELEASE_TOKEN
/// secret, and create releases. Mirrors `DocsManageSheet`.
struct ReleaseManageSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Optional repo to pin/auto-open (e.g. from the release banner deep link).
    var currentRepoFullName: String?

    @State private var repos: [ReleaseRepo] = []
    @State private var search = ""
    @State private var nextCursor: String?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var path = NavigationPath()
    @State private var didAutoNavigate = false
    @State private var showAddRepo = false

    /// The list endpoint doesn't filter server-side, so narrow the loaded page
    /// by the search box client-side.
    private var visibleRepos: [ReleaseRepo] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return repos }
        return repos.filter { $0.repositoryFullName.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                content
            }
            .navigationTitle("Manage Releases")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddRepo = true
                    } label: {
                        Label("Add Repository", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: ReleaseRepo.self) { repo in
                ReleaseRepoDetailView(repo: repo, onClose: { dismiss() })
            }
        }
        .frame(width: 560, height: 560)
        .task { await reload() }
        .sheet(isPresented: $showAddRepo) {
            AddReleaseRepoSheet(
                existingRepoFullNames: Set(repos.map { $0.repositoryFullName.lowercased() }),
                onAdded: { _ in Task { await reload() } }
            )
            .environment(appState)
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search release repositories", text: $search)
                    .textFieldStyle(.plain)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            ForEach(visibleRepos) { repo in
                NavigationLink(value: repo) {
                    ReleaseRepoRow(repo: repo)
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
                Text("No release repositories yet. Set up release publishing from a project's chat to register one.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
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
            let page = try await appState.release.listRepositories()
            repos = page.items
            nextCursor = page.pagination?.nextCursor
            hasMore = page.pagination?.hasMore ?? false
            autoNavigateToCurrentRepoIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            repos = []
            hasMore = false
        }
    }

    private func autoNavigateToCurrentRepoIfNeeded() {
        guard !didAutoNavigate,
              let currentRepoFullName,
              let match = repos.first(where: { $0.repositoryFullName == currentRepoFullName })
        else { return }
        didAutoNavigate = true
        path.append(match)
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await appState.release.listRepositories(cursor: cursor)
            repos.append(contentsOf: page.items)
            nextCursor = page.pagination?.nextCursor
            hasMore = page.pagination?.hasMore ?? false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ReleaseRepoRow: View {
    let repo: ReleaseRepo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.repositoryFullName).font(.body)
                Text(repo.latestReleaseTag.map { "Latest: \($0)" } ?? "No releases yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let tag = repo.latestReleaseTag {
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
