import Foundation
import RxCodeCore
import os

extension AppState {

    /// How often the CI poller refreshes GitHub Actions status for open projects.
    static let ciStatusPollInterval: TimeInterval = 10

    private static let ciSignaturesDefaultsKey = "ciHandledFailureSignatures"

    // MARK: - Poller lifecycle

    /// Start (or restart) the periodic CI-status poll. Idempotent — a prior loop
    /// is cancelled first. Safe to call before sign-in; ticks no-op until signed in.
    func startCIStatusPoller() {
        ciStatusPollerTask?.cancel()
        loadHandledCIFailureSignatures()
        ciStatusPollerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCIStatusOnce()
                let interval = AppState.ciStatusPollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopCIStatusPoller() {
        ciStatusPollerTask?.cancel()
        ciStatusPollerTask = nil
    }

    // MARK: - Display helpers

    /// True when any open project's current branch is red on CI. Drives the
    /// menubar failure indicator.
    var anyCIFailing: Bool {
        ciStatusByProject.values.contains { $0.overallState == .failure }
    }

    /// Projects that have a known CI status, paired with it, sorted failures
    /// first then by project name. Used by the menubar popover and briefing.
    func ciStatusList() -> [(project: Project, status: ProjectCIStatus)] {
        projects
            .compactMap { project in
                ciStatusByProject[project.id].map { (project, $0) }
            }
            .sorted { lhs, rhs in
                if (lhs.1.overallState == .failure) != (rhs.1.overallState == .failure) {
                    return lhs.1.overallState == .failure
                }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
    }

    // MARK: - Refresh

    /// One poll cycle: resolve each GitHub project's current branch, batch-query
    /// autopilot, update `ciStatusByProject`, and react to new failures.
    func refreshCIStatusOnce() async {
        guard isSignedIn else { return }

        // Build one query per project that has a GitHub repo and a resolvable
        // current branch. Keep the originating project alongside each query so we
        // can map the response back without ambiguity.
        var pairs: [(project: Project, query: CIStatusQuery)] = []
        var repoByProject: [UUID: (owner: String, repo: String)] = [:]
        for project in projects {
            guard let slug = project.gitHubRepo else { continue }
            let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            repoByProject[project.id] = (parts[0], parts[1])
            guard let branch = await GitHelper.currentBranch(at: project.path) else { continue }
            pairs.append((project, CIStatusQuery(owner: parts[0], repo: parts[1], branch: branch)))
        }

        // Query each project's current branch (drives the per-project map + CI
        // failure handling) AND every branch shown on briefing cards (so each
        // card can show PR / merge status). De-dup all queries by owner/repo#branch.
        var queriesByKey: [String: CIStatusQuery] = [:]
        for pair in pairs {
            queriesByKey[Self.ciKey(owner: pair.query.owner, repo: pair.query.repo, branch: pair.query.branch)] = pair.query
        }
        for item in threadStore.allBranchBriefingItems() {
            guard let slug = repoByProject[item.projectId] else { continue }
            let key = Self.ciKey(owner: slug.owner, repo: slug.repo, branch: item.branch)
            queriesByKey[key] = CIStatusQuery(owner: slug.owner, repo: slug.repo, branch: item.branch)
        }

        guard !queriesByKey.isEmpty else {
            if !ciStatusByProject.isEmpty || !ciStatusByBranchKey.isEmpty {
                ciStatusByProject = [:]
                ciStatusByBranchKey = [:]
                ciStatusRevision &+= 1
            }
            return
        }

        let response: CIStatusBatchResponse
        do {
            response = try await autopilot.batchCIStatus(Array(queriesByKey.values))
        } catch {
            logger.error("CI status fetch failed: \(error.localizedDescription)")
            return
        }

        // Index results by owner/repo/branch (and a looser owner/repo fallback in
        // case the server echoes a different/absent branch).
        var byKey: [String: ProjectCIStatus] = [:]
        var byRepo: [String: ProjectCIStatus] = [:]
        for result in response.results {
            byKey[Self.ciKey(owner: result.owner, repo: result.repo, branch: result.branch)] = result
            byRepo[Self.ciRepoKey(owner: result.owner, repo: result.repo)] = result
        }

        var next: [UUID: ProjectCIStatus] = [:]
        for pair in pairs {
            let key = Self.ciKey(owner: pair.query.owner, repo: pair.query.repo, branch: pair.query.branch)
            let repoKey = Self.ciRepoKey(owner: pair.query.owner, repo: pair.query.repo)
            guard let status = byKey[key] ?? byRepo[repoKey] else { continue }
            next[pair.project.id] = status
            await handleCITransition(for: pair.project, status: status)
        }

        // Drop status for projects/branches no longer queried (e.g. removed).
        if next != ciStatusByProject || byKey != ciStatusByBranchKey {
            ciStatusByProject = next
            ciStatusByBranchKey = byKey
            ciStatusRevision &+= 1
        }
    }

    /// CI/PR status for an arbitrary project + branch (any branch, not just the
    /// current one), looked up from the branch-keyed map the poller maintains.
    func ciStatus(forProjectId projectId: UUID, branch: String) -> ProjectCIStatus? {
        guard let slug = projects.first(where: { $0.id == projectId })?.gitHubRepo else { return nil }
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return ciStatusByBranchKey[Self.ciKey(owner: parts[0], repo: parts[1], branch: branch)]
    }

    // MARK: - Failure handling

    /// Notify (always) and, when enabled, silently spawn a fix thread — but only
    /// once per distinct failure (keyed by head sha / latest failing run).
    private func handleCITransition(for project: Project, status: ProjectCIStatus) async {
        guard status.overallState == .failure else {
            // Reset so a future failure on this project fires again.
            if lastHandledCIFailureSignature[project.id] != nil {
                lastHandledCIFailureSignature[project.id] = nil
                persistHandledCIFailureSignatures()
            }
            return
        }

        let signature = Self.ciFailureSignature(status)
        guard lastHandledCIFailureSignature[project.id] != signature else { return }
        lastHandledCIFailureSignature[project.id] = signature
        persistHandledCIFailureSignatures()

        let failingNames = status.failing.compactMap(\.workflowName)

        if notificationsEnabled {
            await hookManager.dispatchCIFailed(CIFailedPayload(
                projectId: project.id,
                projectName: project.name,
                failingWorkflowNames: failingNames
            ))
        }

        if enableAutoCIFix {
            await startAutoCIFix(for: project, status: status)
        }
    }

    /// Fire-and-forget fix thread using the project's default agent/model/permission.
    private func startAutoCIFix(for project: Project, status: ProjectCIStatus) async {
        let prompt = Self.ciFixPrompt(status: status, fallbackBranch: status.branch)
        do {
            _ = try await sendCrossProject(
                projectId: project.id,
                threadId: nil,
                prompt: prompt,
                waitForResponse: false
            )
            logger.info("Started auto CI-fix thread for project \(project.name, privacy: .public)")
        } catch {
            logger.error("Failed to start auto CI-fix thread: \(error.localizedDescription)")
        }
    }

    // MARK: - Manual fix (context menu)

    /// Start a fix thread for a failing-CI branch from the briefing card / project
    /// context menu. Mirrors the automatic fix but returns the new thread id so the
    /// caller (desktop tap or relayed mobile command) can navigate to it. `branch`
    /// is nil for a generic project menu — the current branch's status is used.
    @discardableResult
    func createCIFixForBranch(project: Project, branch: String?) async throws -> String {
        let status: ProjectCIStatus?
        if let branch, !branch.isEmpty {
            status = ciStatus(forProjectId: project.id, branch: branch)
        } else {
            status = ciStatusByProject[project.id]
        }
        let prompt = Self.ciFixPrompt(status: status, fallbackBranch: branch)
        let result = try await sendCrossProject(
            projectId: project.id,
            threadId: nil,
            prompt: prompt,
            waitForResponse: false
        )
        if let error = result.error { throw CodeReviewError.sendFailed(error) }
        return result.threadId
    }

    /// Build the fix prompt from a known CI status, seeding the failing run list /
    /// branch / PR context. `fallbackBranch` names the branch when the status is
    /// missing or carries no branch (e.g. a generic project menu).
    static func ciFixPrompt(status: ProjectCIStatus?, fallbackBranch: String?) -> String {
        let branch = status?.branch ?? fallbackBranch ?? "the current branch"
        let prLine = status?.prNumber.map { "PR #\($0) — " } ?? ""
        let failingList = (status?.failing ?? [])
            .map { wf in
                let name = wf.workflowName ?? "workflow"
                if let url = wf.htmlUrl { return "- \(name): \(url)" }
                return "- \(name)"
            }
            .joined(separator: "\n")

        return """
        GitHub Actions CI is failing on branch `\(branch)`. \(prLine)Please fix it.

        Failing workflow run(s):
        \(failingList.isEmpty ? "- (see the GitHub Actions tab for details)" : failingList)

        Investigate the failure (read the run logs at the URLs above if helpful), \
        find the root cause, apply a fix, and run the relevant checks locally to \
        confirm CI will pass before finishing.
        """
    }

    // MARK: - Helpers

    private static func ciKey(owner: String, repo: String, branch: String?) -> String {
        "\(owner.lowercased())/\(repo.lowercased())#\(branch ?? "")"
    }

    private static func ciRepoKey(owner: String, repo: String) -> String {
        "\(owner.lowercased())/\(repo.lowercased())"
    }

    /// A value that changes when the failure changes commit/run, so we re-notify on
    /// genuinely new failures but stay quiet while the same red state persists.
    private static func ciFailureSignature(_ status: ProjectCIStatus) -> String {
        if let sha = status.headSha, !sha.isEmpty { return "sha:\(sha)" }
        let maxRun = status.failing.isEmpty
            ? status.workflows.compactMap(\.runNumber).max()
            : status.workflows.filter { $0.conclusion != nil && $0.conclusion != "success" }.compactMap(\.runNumber).max()
        if let maxRun { return "run:\(maxRun)" }
        return "updated:\(status.lastUpdated ?? "")"
    }

    private func loadHandledCIFailureSignatures() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.ciSignaturesDefaultsKey) as? [String: String] else { return }
        var restored: [UUID: String] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { restored[id] = value }
        }
        lastHandledCIFailureSignature = restored
    }

    private func persistHandledCIFailureSignatures() {
        let raw = Dictionary(uniqueKeysWithValues: lastHandledCIFailureSignature.map { ($0.key.uuidString, $0.value) })
        UserDefaults.standard.set(raw, forKey: Self.ciSignaturesDefaultsKey)
    }
}
