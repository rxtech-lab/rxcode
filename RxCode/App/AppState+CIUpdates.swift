#if os(macOS)
import Foundation
import RxCodeCore

/// High-level CI auto-update intents: batch status refresh + per-project
/// lookups used by the setup banner. Views/hooks call these rather than reaching
/// into `ciUpdates` directly. Mirrors `AppState+Secrets`'s status helpers.
extension AppState {

    /// Refreshes `ciStatusByRepo` for every open project's GitHub repo so the
    /// CI auto-update hook can gate its banner. Leaves the previous cache
    /// untouched on transient errors.
    func refreshCIStatuses() async {
        guard isSignedIn else { ciStatusByRepo = [:]; return }
        let repos = Array(Set(projects.compactMap(\.gitHubRepo)))
        guard !repos.isEmpty else { ciStatusByRepo = [:]; return }
        do {
            let statuses = try await ciUpdates.statuses(forRepos: repos)
            ciStatusByRepo = Dictionary(
                statuses.map { ($0.repositoryFullName.lowercased(), $0) },
                uniquingKeysWith: { _, last in last }
            )
        } catch {
            // Keep the prior cache; a failed poll shouldn't flap the banner.
        }
    }

    /// Whether the project's linked repo is configured for CI auto-updates.
    func projectHasCIUpdates(_ project: Project) -> Bool {
        guard let repo = project.gitHubRepo else { return false }
        return ciStatusByRepo[repo.lowercased()]?.isWatched ?? false
    }
}
#endif
