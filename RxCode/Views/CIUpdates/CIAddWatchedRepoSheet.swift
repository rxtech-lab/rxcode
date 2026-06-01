import RxCodeCore
import SwiftUI

/// Picks a GitHub repository to watch for CI auto-updates. The add API needs
/// `installationId` + `repositoryId` + `repositoryFullName`, none of which the
/// watched-repository listing carries for *new* repos — so we source the
/// accessible-repo list (which does carry the installation/repository ids) from
/// the secrets `repositories/all` endpoint, the same listing `SecretsManageSheet`
/// and `AddDocsRepoSheet` use.
struct CIAddWatchedRepoSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Full names already watched, so they're hidden from the picker.
    let existingRepoFullNames: Set<String>
    /// When set (banner deep-link flow), the picker pre-filters to this repo so
    /// the user lands on it without scrolling.
    var presetRepoFullName: String?
    /// Called after a repo is successfully registered, with its `owner/repo`.
    var onAdded: (String) -> Void

    @State private var repos: [SecretsManagedRepo] = []
    @State private var search = ""
    @State private var nextCursor: String?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var addingFullName: String?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var frequency: CIScanFrequency = .weekly
    @State private var didApplyPreset = false

    private var visibleRepos: [SecretsManagedRepo] {
        repos.filter { !existingRepoFullNames.contains($0.fullName.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Watch Repository for CI Updates")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .frame(width: 520, height: 560)
        .task {
            if let presetRepoFullName, !didApplyPreset {
                didApplyPreset = true
                search = presetRepoFullName
            }
            await reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                Picker("Scan frequency", selection: $frequency) {
                    ForEach(CIScanFrequency.allCases) { freq in
                        Text(freq.displayName).tag(freq)
                    }
                }
                Text("How often autopilot scans this repo's workflows and opens a PR when actions are outdated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search repositories", text: $search)
                        .textFieldStyle(.plain)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
                ForEach(visibleRepos) { repo in
                    Button {
                        Task { await add(repo) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.fullName).font(.body)
                                if repo.isCurrent {
                                    Text("Current project").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if addingFullName == repo.fullName {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "plus.circle").foregroundStyle(.tint)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(addingFullName != nil)
                }
                if hasMore {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        HStack { Spacer(); Text("Load more"); Spacer() }
                    }
                    .disabled(isLoading)
                }
                if visibleRepos.isEmpty, !isLoading, errorMessage == nil {
                    Text("No repositories available to add.")
                        .foregroundStyle(.secondary).font(.callout)
                }
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
            let page = try await appState.secrets.listManagedRepositories(search: search)
            repos = page.items
            nextCursor = page.pagination.nextCursor
            hasMore = page.pagination.hasMore
        } catch {
            errorMessage = error.localizedDescription
            repos = []
            hasMore = false
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await appState.secrets.listManagedRepositories(search: search, cursor: cursor)
            repos.append(contentsOf: page.items)
            nextCursor = page.pagination.nextCursor
            hasMore = page.pagination.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func add(_ repo: SecretsManagedRepo) async {
        addingFullName = repo.fullName
        errorMessage = nil
        defer { addingFullName = nil }
        do {
            _ = try await appState.ciUpdates.addWatchedRepository(
                AddWatchedRepoBody(
                    installationId: repo.installationId,
                    repositoryId: repo.id,
                    repositoryFullName: repo.fullName,
                    scanFrequency: frequency
                )
            )
            onAdded(repo.fullName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
