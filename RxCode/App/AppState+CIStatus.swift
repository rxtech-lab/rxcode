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
        for project in projects {
            guard let slug = project.gitHubRepo else { continue }
            let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            guard let branch = await GitHelper.currentBranch(at: project.path) else { continue }
            pairs.append((project, CIStatusQuery(owner: parts[0], repo: parts[1], branch: branch)))
        }

        guard !pairs.isEmpty else {
            if !ciStatusByProject.isEmpty {
                ciStatusByProject = [:]
                ciStatusRevision &+= 1
            }
            return
        }

        let response: CIStatusBatchResponse
        do {
            response = try await autopilot.batchCIStatus(pairs.map(\.query))
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

        // Drop status for projects no longer queried (e.g. removed).
        if next != ciStatusByProject {
            ciStatusByProject = next
            ciStatusRevision &+= 1
        }
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
        let branch = status.branch ?? "the current branch"
        let prLine = status.prNumber.map { "PR #\($0) — " } ?? ""
        let failingList = status.failing
            .map { wf in
                let name = wf.workflowName ?? "workflow"
                if let url = wf.htmlUrl { return "- \(name): \(url)" }
                return "- \(name)"
            }
            .joined(separator: "\n")

        let prompt = """
        GitHub Actions CI is failing on branch `\(branch)`. \(prLine)Please fix it.

        Failing workflow run(s):
        \(failingList.isEmpty ? "- (see the GitHub Actions tab for details)" : failingList)

        Investigate the failure (read the run logs at the URLs above if helpful), \
        find the root cause, apply a fix, and run the relevant checks locally to \
        confirm CI will pass before finishing.
        """

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
