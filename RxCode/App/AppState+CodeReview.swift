import Foundation
import RxCodeCore

/// Errors surfaced while starting a manual code review from a briefing card,
/// project menu, or thread row.
enum CodeReviewError: LocalizedError {
    case unknownThread
    case unknownProject
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownThread:
            return "Couldn't find the thread to review."
        case .unknownProject:
            return "Couldn't find the project to review."
        case .sendFailed(let message):
            return "Couldn't start the code review.\n\n\(message)"
        }
    }
}

extension AppState {

    /// Label stamped on manually-started review threads (matches the built-in
    /// Code Review hook so they show the same `[Code Review]` chip and nest in
    /// the sidebar review UI).
    static let manualCodeReviewLabel = "Code Review"

    /// Session ids of `[Code Review]` threads (manual or hook-spawned),
    /// identified by their thread label. Used to keep review threads out of
    /// briefings — both desktop and the mobile snapshot — even for summaries
    /// persisted before review threads were excluded at write time.
    var codeReviewThreadIds: Set<String> {
        Set(allSessionSummaries
            .filter { $0.threadLabel == Self.manualCodeReviewLabel }
            .map(\.id))
    }

    // MARK: - Branch-level review

    /// Start a `[Code Review]` thread that reviews *all* the changes on `branch`,
    /// grounded in the branch briefing and the summaries of every thread that ran
    /// on it. The reviewer inspects the branch diff itself (it runs in `.auto`
    /// mode), so no diff needs to be computed here. Returns the new thread id.
    @discardableResult
    func createCodeReviewForBranch(project: Project, branch: String) async throws -> String {
        let briefing = threadStore.allBranchBriefingItems()
            .first(where: { $0.projectId == project.id && $0.branch == branch })?
            .briefing ?? ""
        let summaries = threadStore.allThreadSummaryItems()
            .filter { $0.projectId == project.id && $0.branch == branch }
            .sorted { $0.updatedAt > $1.updatedAt }
        let prompt = Self.branchCodeReviewPrompt(branch: branch, briefing: briefing, summaries: summaries)
        return try await startCodeReviewThread(projectId: project.id, parentThreadId: nil, prompt: prompt)
    }

    // MARK: - Thread-level review

    /// Start a `[Code Review]` thread nested under `sessionId` that reviews the
    /// files that thread changed — the manual equivalent of the built-in Code
    /// Review hook. Returns the new thread id.
    @discardableResult
    func createCodeReviewForThread(sessionId: String) async throws -> String {
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionId })
            ?? threadStore.fetch(id: sessionId)?.toSummary() else {
            throw CodeReviewError.unknownThread
        }
        guard let project = projects.first(where: { $0.id == summary.projectId }) else {
            throw CodeReviewError.unknownProject
        }

        // Files this thread touched, de-duplicated in first-seen order.
        var seen = Set<String>()
        var changedFiles: [String] = []
        for edit in threadStore.fetchFileEdits(sessionId: sessionId) where seen.insert(edit.path).inserted {
            changedFiles.append(edit.path)
        }

        // Pull the task/response from in-memory state when the thread is loaded;
        // fall back to the thread title (always available) for an idle thread
        // whose messages aren't currently in memory.
        let messages = stateForSession(sessionId).messages
        let task = messages.first(where: {
            $0.role == .user && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content ?? summary.title
        let finalResponse = lastAssistantResponseText(in: messages)

        let prompt = Self.threadCodeReviewPrompt(
            task: task,
            changedFiles: changedFiles,
            finalResponse: finalResponse
        )
        return try await startCodeReviewThread(projectId: project.id, parentThreadId: sessionId, prompt: prompt)
    }

    // MARK: - Shared launch

    /// Spawn the review thread through the normal send pipeline. Runs in `.auto`
    /// mode (so the reviewer can read files / run `git diff` without per-tool
    /// prompts) with hooks skipped (the review thread shouldn't trigger its own
    /// review). Fire-and-forget — returns as soon as the thread id is known so
    /// the caller can navigate to it while the review runs.
    private func startCodeReviewThread(
        projectId: UUID,
        parentThreadId: String?,
        prompt: String
    ) async throws -> String {
        let result = try await sendCrossProject(
            projectId: projectId,
            threadId: nil,
            prompt: prompt,
            permissionMode: .auto,
            waitForResponse: false,
            timeoutSeconds: 600,
            parentThreadId: parentThreadId,
            threadLabel: Self.manualCodeReviewLabel,
            skipHooks: true
        )
        if let error = result.error { throw CodeReviewError.sendFailed(error) }
        return result.threadId
    }

    // MARK: - Prompts

    private static let reviewMarker = "REVIEW_RESULT:"

    static func branchCodeReviewPrompt(
        branch: String,
        briefing: String,
        summaries: [ThreadSummaryItem]
    ) -> String {
        let trimmedBriefing = briefing.trimmingCharacters(in: .whitespacesAndNewlines)
        let briefingSection = trimmedBriefing.isEmpty ? "(no briefing recorded)" : trimmedBriefing
        let threadList: String
        if summaries.isEmpty {
            threadList = "(no thread summaries recorded)"
        } else {
            threadList = summaries.map { item in
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = item.summary
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n").first.map(String.init) ?? ""
                return summary.isEmpty ? "- \(title)" : "- \(title) — \(summary)"
            }.joined(separator: "\n")
        }

        return """
        You are reviewing all the code changes on branch `\(branch)` in this repository. Do not edit any files — only review.

        ## What this branch set out to do (briefing)
        \(briefingSection)

        ## Threads that ran on this branch
        \(threadList)

        ## What to do
        1. Determine the branch's base (usually the repository's default branch, e.g. `main`) and inspect the actual diff. For example run `git diff $(git merge-base HEAD main)...HEAD --stat` then read the changed files, or `git diff main...HEAD`.
        2. Judge whether the changes correctly and safely accomplish the work described above. Look for bugs, missed requirements, regressions, security issues, and obvious quality problems.
        3. List the specific, actionable issues you find (file + line where possible).

        End your reply with a single line — exactly one of:
        `\(reviewMarker) PASS`  (the changes look good as-is)
        `\(reviewMarker) FAIL`  (changes are needed)
        """
    }

    static func threadCodeReviewPrompt(
        task: String,
        changedFiles: [String],
        finalResponse: String
    ) -> String {
        let fileList = changedFiles.isEmpty
            ? "(no recorded file edits — inspect the working tree / recent commits for what changed)"
            : changedFiles.map { "- \($0)" }.joined(separator: "\n")
        let response = finalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        let responseSection = response.isEmpty ? "(no final response recorded)" : response

        return """
        You are reviewing another agent's code change in this repository. Do not edit any files — only review.

        ## The user's task
        \(task)

        ## Files the agent changed
        \(fileList)

        ## The agent's final response
        \(responseSection)

        ## What to do
        Inspect the changed files and judge whether the change correctly and safely accomplishes the task. Look for bugs, missed requirements, regressions, and obvious quality problems.

        End your reply with a single line — exactly one of:
        `\(reviewMarker) PASS`  (the change is good as-is)
        `\(reviewMarker) FAIL`  (changes are needed)

        If you FAIL the review, list the specific, actionable issues to fix above that line.
        """
    }
}
