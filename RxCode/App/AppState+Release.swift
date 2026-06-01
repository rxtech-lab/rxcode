#if os(macOS)
import Foundation
import RxCodeCore

/// High-level release intents layered over `ReleaseService`. Views and the
/// release hook call these; they never build requests directly.
extension AppState {

    // MARK: - Status (batch)

    /// Refreshes `releaseStatusByRepo` for every open project's GitHub repo so
    /// the release hook can decide whether to surface the "set up release"
    /// banner and the sidebar / briefing can gate the "Create Release" action.
    /// Leaves the previous cache untouched on transient errors.
    func refreshReleaseStatuses() async {
        guard isSignedIn else { releaseStatusByRepo = [:]; return }
        let repos = Array(Set(projects.compactMap(\.gitHubRepo)))
        guard !repos.isEmpty else { releaseStatusByRepo = [:]; return }
        do {
            let statuses = try await release.statuses(forRepos: repos)
            releaseStatusByRepo = Dictionary(
                statuses.map { ($0.fullName.lowercased(), $0) },
                uniquingKeysWith: { _, last in last }
            )
        } catch {
            // Keep the prior cache; a failed poll shouldn't flip the banner.
        }
    }

    /// Whether the project's linked repo has a release workflow set up
    /// (registered + a selected dispatchable workflow). Gates the "Create
    /// Release" affordances.
    func projectHasReleaseWorkflow(_ project: Project) -> Bool {
        guard let repo = project.gitHubRepo else { return false }
        return releaseStatusByRepo[repo.lowercased()]?.hasReleaseWorkflow ?? false
    }

    /// Whether the project's linked repo is registered with the release service.
    /// Returns `nil` when we have no status for the repo yet (treat as unknown).
    func projectReleaseConfigured(_ repoFullName: String) -> Bool? {
        releaseStatusByRepo[repoFullName.lowercased()]?.isManaged
    }

    /// The latest released version (tag) for the project's repo, if any. Drives
    /// the briefing card version chip.
    func projectLatestReleaseVersion(_ project: Project) -> String? {
        guard let repo = project.gitHubRepo else { return nil }
        return releaseStatusByRepo[repo.lowercased()]?.latestVersion
    }
}
#endif
