import RxCodeCore
import SwiftUI

/// Top-level "Manage Docs" sheet: lists every docs-managed repository and drills
/// into a repo to view its documents and mint CI upload tokens. Mirrors
/// `SecretsManageSheet`.
struct DocsManageSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Optional repo to pin/auto-open (e.g. from the docs banner deep link).
    var currentRepoFullName: String?

    @State private var repos: [DocsRepo] = []
    @State private var search = ""
    @State private var nextCursor: String?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var path = NavigationPath()
    @State private var didAutoNavigate = false
    @State private var showAddRepo = false

    /// The list endpoint doesn't filter server-side, so narrow the loaded page
    /// by the search box client-side.
    private var visibleRepos: [DocsRepo] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return repos }
        return repos.filter { $0.repositoryFullName.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                content
            }
            .navigationTitle("Manage Docs")
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
            .navigationDestination(for: DocsRepo.self) { repo in
                DocsRepoDetailView(repo: repo, onClose: { dismiss() })
            }
        }
        .frame(width: 560, height: 560)
        .task { await reload() }
        .sheet(isPresented: $showAddRepo) {
            AddDocsRepoSheet(
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
                TextField("Search documentation repositories", text: $search)
                    .textFieldStyle(.plain)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }
            ForEach(visibleRepos) { repo in
                NavigationLink(value: repo) {
                    DocsRepoRow(repo: repo)
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
                Text("No documentation repositories yet. Set up docs publishing from a project's chat to index its docs.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
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

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await appState.docs.listRepositories(search: search)
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
            let page = try await appState.docs.listRepositories(search: search, cursor: cursor)
            repos.append(contentsOf: page.items)
            nextCursor = page.pagination?.nextCursor
            hasMore = page.pagination?.hasMore ?? false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DocsRepoRow: View {
    let repo: DocsRepo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.repositoryFullName).font(.body)
                Text("\(repo.documentsCount ?? 0) document(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
