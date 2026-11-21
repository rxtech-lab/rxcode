import Foundation
import RxCodeCore

/// Whether a pushed branch already has a pull request on GitHub.
enum BranchPullRequestPresence: Equatable {
    /// A PR exists for the branch (open, closed, or merged). `url` is nil when
    /// the server reported a PR without a usable link.
    case exists(url: URL?)
    /// The lookup succeeded and the branch has no PR yet.
    case missing
}

extension AppState {

    // MARK: - Lookup

    /// Look up whether `branch` of `repository` (`owner/repo`) has a pull
    /// request. Unlike ``fetchPullRequest(forRepository:branch:)`` this tells a
    /// missing PR apart from a failed lookup: it returns `nil` when the status
    /// can't be determined, so callers never suggest creating a PR that may
    /// already exist.
    func lookUpBranchPullRequest(repository: String, branch: String) async -> BranchPullRequestPresence? {
        if let cached = pullRequest(forRepository: repository, branch: branch) {
            return .exists(url: cached.url)
        }
        let parts = repository.split(separator: "/")
        guard isSignedIn, parts.count == 2 else { return nil }
        let query = CIStatusQuery(owner: String(parts[0]), repo: String(parts[1]), branch: branch)
        let repoKey = repository.lowercased()
        guard let response = try? await autopilot.batchCIStatus([query]), !Task.isCancelled else { return nil }
        guard let status = response.results.first(where: {
            $0.branch == branch && Self.ciRepoKey(owner: $0.owner, repo: $0.repo) == repoKey
        }) else { return .missing }
        guard status.pullRequestState != nil || status.prNumber != nil else { return .missing }
        return .exists(url: ThreadPullRequest(repository: repository, status: status)?.url)
    }

    /// The branch `remote/HEAD` points at (e.g. `main`), used as the PR base
    /// and to avoid suggesting a PR for the default branch itself.
    nonisolated static func remoteDefaultBranch(remote: String, at root: String) async -> String? {
        if let output = await GitHelper.run(["symbolic-ref", "--short", "refs/remotes/\(remote)/HEAD"], at: root) {
            let ref = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(remote)/"
            if ref.hasPrefix(prefix), ref.count > prefix.count { return String(ref.dropFirst(prefix.count)) }
        }
        for candidate in ["main", "master"] {
            if await GitHelper.run(["rev-parse", "--verify", "--quiet", "refs/remotes/\(remote)/\(candidate)"], at: root) != nil {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Draft

    /// Draft a Conventional-Commit PR title and a markdown body for the branch
    /// checked out at `root`. The agent sees the branch briefing (when a project
    /// tracks this checkout) plus the commits and diff stat since `base`.
    /// `model` nil uses the summarization settings.
    func draftPullRequest(
        root: String,
        branch: String,
        remote: String,
        base: String?,
        model: AgentModel?
    ) async -> (title: String, body: String) {
        let context = await pullRequestDraftContext(root: root, branch: branch, remote: remote, base: base)
        return await generateValidatedPullRequestContent(
            briefing: context,
            branch: branch,
            model: model,
            cwd: root
        )
    }

    private func pullRequestDraftContext(root: String, branch: String, remote: String, base: String?) async -> String {
        var sections: [String] = []

        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        if let project = projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardizedRoot }),
           let briefing = threadStore.combinedBranchBriefing(projectId: project.id, branch: branch)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !briefing.isEmpty {
            sections.append("Work summary:\n\(String(briefing.prefix(3_000)))")
        }

        // Commits unique to this branch; fall back to recent history when the
        // base isn't available locally.
        let range = base.map { "\(remote)/\($0)..HEAD" }
        var logArgs = ["log", "--no-merges", "--format=- %s%n%w(0,2,2)%b", "-n", "40"]
        if let range { logArgs.append(range) }
        var log = await GitHelper.run(logArgs, at: root)
        if log?.isEmpty != false, range != nil {
            log = await GitHelper.run(["log", "--no-merges", "--format=- %s%n%w(0,2,2)%b", "-n", "15"], at: root)
        }
        if let log = log?.trimmingCharacters(in: .whitespacesAndNewlines), !log.isEmpty {
            sections.append("Commits:\n\(String(log.prefix(2_500)))")
        }

        if let base,
           let stat = await GitHelper.run(["diff", "--stat", "\(remote)/\(base)...HEAD"], at: root)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !stat.isEmpty {
            sections.append("Files changed:\n\(String(stat.suffix(800)))")
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Create

    /// Open a pull request for the already-pushed `branch` of `repository`
    /// (`owner/repo`) with a user-reviewed title and body, then refresh branch
    /// status so PR prompts disappear. Returns the PR URL.
    func openPullRequest(
        repository: String,
        branch: String,
        base: String?,
        title: String,
        body: String
    ) async throws -> URL {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw PullRequestError.noGitHubRepo }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let response: CreatePullRequestResponse
        do {
            response = try await autopilot.createPullRequest(
                CreatePullRequestRequest(
                    owner: parts[0],
                    repo: parts[1],
                    head: branch,
                    base: base,
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: trimmedBody.isEmpty ? nil : trimmedBody
                )
            )
        } catch {
            throw PullRequestError.createFailed(error.localizedDescription)
        }
        await refreshCIStatusOnce()
        guard let url = URL(string: response.prUrl) else {
            throw PullRequestError.createFailed("The server returned an invalid PR URL.")
        }
        return url
    }
}
