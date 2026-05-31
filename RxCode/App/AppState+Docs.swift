#if os(macOS)
import Foundation
import RxCodeCore

/// High-level docs intents layered over `DocsService`. Views and the docs hook
/// call these; they never build requests directly.
extension AppState {

    // MARK: - Status (batch)

    /// Refreshes `docsStatusByRepo` for every open project's GitHub repo so the
    /// docs hook can decide whether to surface the "set up docs" banner. Leaves
    /// the previous cache untouched on transient errors.
    func refreshDocsStatuses() async {
        guard isSignedIn else { docsStatusByRepo = [:]; return }
        let repos = Array(Set(projects.compactMap(\.gitHubRepo)))
        guard !repos.isEmpty else { docsStatusByRepo = [:]; return }
        do {
            let statuses = try await docs.statuses(forRepos: repos)
            docsStatusByRepo = Dictionary(
                statuses.map { ($0.repository.lowercased(), $0) },
                uniquingKeysWith: { _, last in last }
            )
        } catch {
            // Keep the prior cache; a failed poll shouldn't flip the banner.
        }
    }

    /// Whether the project's linked repo has docs indexed. Returns `nil` when we
    /// have no status for the repo yet (caller should treat as "unknown").
    func projectDocsState(_ repoFullName: String) -> Bool? {
        docsStatusByRepo[repoFullName.lowercased()]?.hasDocs
    }
}
#endif
