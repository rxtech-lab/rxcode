import Foundation
import RxAuthSwift
import RxCodeCore
import os

nonisolated struct ThreadPullRequest: Codable, Equatable, Sendable {
    let repository: String
    let url: URL
    let number: Int?
    let state: PRState?

    init?(repository: String, number: Int?, state: PRState?, reportedURL: String?) {
        if let reportedURL = reportedURL.flatMap(URL.init(string:)),
           reportedURL.scheme == "https", reportedURL.host != nil {
            url = reportedURL
        } else if let number, number > 0,
                  let fallback = URL(string: "https://github.com/\(repository)/pull/\(number)") {
            url = fallback
        } else {
            return nil
        }
        self.repository = repository.lowercased()
        self.number = number
        self.state = state
    }
}

/// Last published branch results and cross-branch PR matches for one workspace account.
nonisolated struct BranchStatusSnapshot: Codable, Sendable {
    let accountID: String?
    var byBranch: [String: ProjectCIStatus] = [:]
    var inferredBySession: [String: ThreadPullRequest] = [:]
}

extension AppState {

    /// How often the CI poller refreshes GitHub Actions status for open projects.
    static let ciStatusPollInterval: TimeInterval = 60

    private static let ciSignaturesDefaultsKey = "ciHandledFailureSignatures"
    private static let ciEventsDefaultsKey = "ciHandledFailureEvents"
    static let branchStatusAccountKey = "branchStatusAccountID"

    // MARK: - Poller lifecycle

    /// Both startup paths call this. Whichever finishes last starts the first
    /// poll with the signed-in account and the complete local thread index.
    func startCIStatusPoller() {
        guard isSignedIn else { return }
        let accountID = rxUser?.id
        workspaceDefaults.set(accountID, for: Self.branchStatusAccountKey)
        guard isInitialized else { return }
        if branchStatus.accountID != accountID {
            stopCIStatusPoller()
            resetCIStatus(accountID: accountID)
        }
        guard ciStatusPollerTask == nil else { return }
        loadHandledCIFailureSignatures()
        ciStatusPollerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshCIStatusOnce()
                await self?.refreshInferredThreadPullRequests()
                let interval = AppState.ciStatusPollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopCIStatusPoller() {
        ciStatusPollerTask?.cancel()
        ciStatusPollerTask = nil
        ciStatusRequestID = nil
    }

    /// While sign-in is being restored, the local workspace can display its
    /// last known badges. Once resolved, only the matching account can use them.
    private func canDisplayBranchStatus(accountID: String?) -> Bool {
        switch rxAuth.manager.authState {
        case .unknown: return accountID != nil
        case .authenticated: return accountID == rxUser?.id
        case .unauthenticated: return false
        }
    }

    func restoreBranchStatus(_ snapshot: BranchStatusSnapshot?) {
        guard let snapshot, let owner = snapshot.accountID, !isInitialized,
              canDisplayBranchStatus(accountID: owner) else { return }
        if rxAuth.manager.authState == .unknown, workspaceDefaults.string(for: Self.branchStatusAccountKey) != owner {
            return
        }
        branchStatus = snapshot
        ciStatusRevision &+= 1
    }

    private func resetCIStatus(accountID: String?) {
        branchStatus = BranchStatusSnapshot(accountID: accountID)
        ciStatusByProject = [:]
        ciStatusRevision &+= 1
    }

    func clearCIStatus() async {
        stopCIStatusPoller()
        workspaceDefaults.set(nil as String?, for: Self.branchStatusAccountKey)
        resetCIStatus(accountID: nil)
        await persistBranchStatus()
    }

    func persistBranchStatus() async {
        do {
            try await CacheStorageService.shared.saveBranchStatus(branchStatus, workspaceID: activeWorkspace.id)
        } catch {
            logger.error("Could not save cached branch status: \(error.localizedDescription)")
        }
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

    func pullRequest(forThread summary: ChatSession.Summary, in project: Project) -> ThreadPullRequest? {
        guard canDisplayBranchStatus(accountID: branchStatus.accountID),
              summary.projectId == project.id, let repository = project.gitHubRepo else { return nil }
        if let direct = pullRequestForRecordedBranch(summary, repository: repository) { return direct }
        let inferred = branchStatus.inferredBySession[summary.id]
        return inferred?.repository == repository.lowercased() ? inferred : nil
    }

    private func pullRequestForRecordedBranch(
        _ summary: ChatSession.Summary,
        repository: String
    ) -> ThreadPullRequest? {
        let branches = summary.worktreeBranch.map { [$0] }
            ?? ciBranchesBySessionId[summary.id]
            ?? summary.parentThreadId.flatMap { ciBranchesBySessionId[$0] }
            ?? []
        for branch in branches {
            let key = "\(repository.lowercased())#\(branch)"
            guard let status = branchStatus.byBranch[key], status.found,
                  let pullRequest = ThreadPullRequest(
                    repository: repository,
                    number: status.prNumber,
                    state: status.pullRequestState,
                    reportedURL: status.prUrl
                  ) else { continue }
            return pullRequest
        }
        return nil
    }

    func recordThreadCheckout(sessionId: String, projectId: UUID, cwd: String, streamId: UUID) async {
        guard projectId != Project.globalChatID,
              sessionStates[sessionId]?.worktreeBranch == nil,
              let branch = await GitHelper.currentBranch(at: cwd),
              !Task.isCancelled, sessionStates[sessionId]?.activeStreamId == streamId else { return }
        threadStore.setCheckoutBranch(sessionId: sessionId, branch: branch)
        if ciBranchesBySessionId[sessionId]?.first != branch {
            ciBranchesBySessionId[sessionId] = [branch]
        }
    }

    // MARK: - Refresh

    /// One poll cycle: resolve each GitHub project's current branch, batch-query
    /// autopilot, update `ciStatusByProject`, and react to new failures.
    func refreshCIStatusOnce() async {
        guard isInitialized, isSignedIn, !Task.isCancelled else { return }
        let accountID = rxUser?.id
        let requestID = UUID()
        ciStatusRequestID = requestID
        func isCurrentRequest() -> Bool {
            !Task.isCancelled && ciStatusRequestID == requestID && isSignedIn && rxUser?.id == accountID
        }

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

        // A thread can track a branch before it gets a briefing, and the PR
        // can outlive both a checkout and a deleted worktree or remote branch.
        let previousBranches = ciBranchesBySessionId
        let storedBranches = repoByProject.isEmpty ? [:] : await threadStoreReader.loadThreadBranches()
        guard isCurrentRequest() else { return }
        var threadBranches: [String: [String]] = [:]
        for summary in allSessionSummaries {
            guard let slug = repoByProject[summary.projectId] else { continue }
            // A turn can record its checkout while the background reader is running.
            let liveBranches = ciBranchesBySessionId[summary.id]
            let branches = summary.worktreeBranch.map { [$0] }
                ?? (liveBranches == previousBranches[summary.id] ? storedBranches[summary.id] : liveBranches)
            guard let branches else { continue }
            threadBranches[summary.id] = branches
            for branch in branches {
                let key = Self.ciKey(owner: slug.owner, repo: slug.repo, branch: branch)
                queriesByKey[key] = CIStatusQuery(owner: slug.owner, repo: slug.repo, branch: branch)
            }
        }
        if ciBranchesBySessionId != threadBranches {
            ciBranchesBySessionId = threadBranches
        }

        guard !queriesByKey.isEmpty else {
            if !ciStatusByProject.isEmpty || !branchStatus.byBranch.isEmpty {
                ciStatusByProject = [:]
                branchStatus.byBranch = [:]
                ciStatusRevision &+= 1
                await persistBranchStatus()
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
        guard isCurrentRequest() else { return }

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
        }

        // Drop status for projects/branches no longer queried (e.g. removed).
        if next != ciStatusByProject || byKey != branchStatus.byBranch {
            ciStatusByProject = next
            branchStatus.byBranch = byKey
            ciStatusRevision &+= 1
            await persistBranchStatus()
        }

        for pair in pairs {
            guard isCurrentRequest() else { return }
            if let status = next[pair.project.id] {
                await handleCITransition(for: pair.project, status: status)
            }
        }
    }

    /// Recover links for threads whose edits were picked up by a PR on another branch.
    private func refreshInferredThreadPullRequests() async {
        guard isSignedIn, !Task.isCancelled else { return }
        let accountID = rxUser?.id
        let projects = projects
        let repositories = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
            project.gitHubRepo.map { (project.id, $0) }
        })
        let unmatched = allSessionSummaries.filter {
            guard let repository = repositories[$0.projectId], threadHasDiffPreview(sessionId: $0.id) else { return false }
            return pullRequestForRecordedBranch($0, repository: repository) == nil
        }
        guard !unmatched.isEmpty else {
            if !branchStatus.inferredBySession.isEmpty {
                branchStatus.inferredBySession = [:]
                await persistBranchStatus()
            }
            return
        }
        do {
            let revisions = try await autopilot.recentPullRequestRevisions()
            let matches = await threadPullRequestMatcher.match(
                revisions,
                to: unmatched,
                in: projects,
                reader: threadStoreReader
            )
            guard !Task.isCancelled, isSignedIn, rxUser?.id == accountID, matches != branchStatus.inferredBySession else { return }
            branchStatus.inferredBySession = matches
            await persistBranchStatus()
        } catch {
            if !Task.isCancelled {
                logger.error("Thread pull request lookup failed: \(error.localizedDescription)")
            }
        }
    }

    /// CI/PR status for an arbitrary project + branch (any branch, not just the
    /// current one), looked up from the branch-keyed map the poller maintains.
    func ciStatus(forProjectId projectId: UUID, branch: String) -> ProjectCIStatus? {
        guard canDisplayBranchStatus(accountID: branchStatus.accountID),
              let slug = projects.first(where: { $0.id == projectId })?.gitHubRepo else { return nil }
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return branchStatus.byBranch[Self.ciKey(owner: parts[0], repo: parts[1], branch: branch)]
    }

    // MARK: - Failure handling

    /// Announce each newly observed failed run once. Auto-fix retains its
    /// separate per-commit signature so multiple workflows do not spawn fixes.
    private func handleCITransition(for project: Project, status: ProjectCIStatus) async {
        guard status.overallState == .failure else {
            // Reset so a future failure on this project fires again.
            if lastHandledCIFailureSignature[project.id] != nil {
                lastHandledCIFailureSignature[project.id] = nil
                persistHandledCIFailureSignatures()
            }
            return
        }

        var ledger = ciFailureEventLedgers[project.id] ?? CIFailureEventLedger()
        let newFailures = ledger.consume(status)
        ciFailureEventLedgers[project.id] = ledger
        if !newFailures.isEmpty, let data = try? JSONEncoder().encode(ciFailureEventLedgers) {
            UserDefaults.standard.set(data, forKey: Self.ciEventsDefaultsKey)
        }

        if notificationsEnabled, !newFailures.isEmpty {
            await hookManager.dispatchCIFailed(CIFailedPayload(
                projectId: project.id,
                projectName: project.name,
                failingWorkflowNames: newFailures.compactMap(\.workflowName),
                runURL: newFailures.compactMap(\.htmlUrl).first
            ))
        }

        let signature = Self.ciFailureSignature(status)
        guard lastHandledCIFailureSignature[project.id] != signature else { return }
        lastHandledCIFailureSignature[project.id] = signature
        persistHandledCIFailureSignatures()
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
                waitForResponse: false,
                skipHooks: true
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
            waitForResponse: false,
            skipHooks: true
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
        if let data = UserDefaults.standard.data(forKey: Self.ciEventsDefaultsKey),
           let ledgers = try? JSONDecoder().decode([UUID: CIFailureEventLedger].self, from: data) {
            ciFailureEventLedgers = ledgers
        }
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
