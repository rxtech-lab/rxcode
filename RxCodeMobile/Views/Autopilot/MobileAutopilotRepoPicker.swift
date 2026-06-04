import RxCodeCore
import RxCodeSync
import SwiftUI

/// Picks an accessible GitHub repository to register for a feature (docs,
/// release, CI). Mirrors the desktop add-repo sheets, which all source the
/// accessible-repo list (carrying installation + repository ids) from the
/// secrets `repositories/all` listing. The picked repo is handed back via
/// `onSelect`; the caller performs the feature-specific registration.
struct MobileAutopilotRepoPicker: View {
    @EnvironmentObject private var state: MobileAppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let title: String
    /// Full names already registered, hidden from the picker.
    let existingRepoFullNames: Set<String>
    let onSelect: (SecretsManagedRepo) async throws -> Void

    @State private var repos: [SecretsManagedRepo] = []
    @State private var search = ""
    @State private var nextCursor: String?
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var isOpeningInstallURL = false
    @State private var addingFullName: String?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private var visibleRepos: [SecretsManagedRepo] {
        repos.filter { !existingRepoFullNames.contains($0.fullName.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                ForEach(visibleRepos) { repo in
                    Button {
                        Task { await select(repo) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(repo.fullName).foregroundStyle(.primary)
                                if repo.isCurrent {
                                    Text("Current project").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if addingFullName == repo.fullName {
                                ProgressView()
                            } else {
                                Image(systemName: "plus.circle").foregroundStyle(.tint)
                            }
                        }
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
            .mobileAutopilotLoadingOverlay(isLoading && repos.isEmpty)
            .searchable(text: $search)
            .onChange(of: search) { _, _ in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await reload()
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await openGitHubAppInstallURL() }
                    } label: {
                        if isOpeningInstallURL {
                            ProgressView()
                        } else {
                            Image(systemName: "app.badge.checkmark")
                        }
                    }
                    .accessibilityLabel("Install GitHub App")
                    .disabled(isOpeningInstallURL)
                }
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await state.listAutopilotRepos(search: search)
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
            let page = try await state.listAutopilotRepos(search: search, cursor: cursor)
            repos.append(contentsOf: page.items)
            nextCursor = page.pagination.nextCursor
            hasMore = page.pagination.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ repo: SecretsManagedRepo) async {
        addingFullName = repo.fullName
        defer { addingFullName = nil }
        do {
            try await onSelect(repo)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openGitHubAppInstallURL() async {
        isOpeningInstallURL = true
        errorMessage = nil
        defer { isOpeningInstallURL = false }
        do {
            openURL(try await state.githubAppInstallURL())
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
