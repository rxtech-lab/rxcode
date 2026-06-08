import Foundation
import RxCodeCore

/// Errors surfaced while starting a manual commit turn from a project, briefing,
/// or thread menu.
enum CommitFilesError: LocalizedError {
    case unknownThread
    case unknownProject
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownThread:
            return "Couldn't find the thread to commit."
        case .unknownProject:
            return "Couldn't find the project to commit."
        case .sendFailed(let message):
            return "Couldn't start the commit.\n\n\(message)"
        }
    }
}

extension AppState {
    static let manualCommitLabel = "Commit"

    // MARK: - Commit affordance gating

    /// Whether the thread-level "Commit Files" action should be offered: hidden
    /// when the thread recorded no file edits. Read directly from the local
    /// `ThreadStore`, so it's always accurate on the desktop.
    func threadHasFileChanges(sessionId: String) -> Bool {
        threadStore.fileEditCount(sessionId: sessionId) > 0
    }

    /// Whether the project-level "Commit All Changes" action should be offered.
    /// Hidden only when the working tree is positively known to be clean; an
    /// unresolved project (no cached entry yet) keeps the action visible so a
    /// not-yet-computed status never hides a valid commit. See `projectGitDirty`.
    func projectHasUncommittedChanges(_ projectId: UUID) -> Bool {
        projectGitDirty[projectId] ?? true
    }

    /// Recompute the working-tree dirty flag for every known project and publish
    /// the result into `projectGitDirty`. Git calls run concurrently so a large
    /// project list doesn't serialize on disk I/O. A failed/`nil` status (not a
    /// repo, transient error) leaves the project "unknown" rather than marking it
    /// clean, so the Commit All action isn't hidden on a hiccup.
    func refreshProjectGitDirty() async {
        let inputs = projects.map { (id: $0.id, path: $0.path) }
        let results = await withTaskGroup(of: (UUID, Bool?).self) { group in
            for input in inputs {
                group.addTask {
                    let status = await GitHelper.run(["status", "--porcelain"], at: input.path)
                    let dirty = status.map {
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    return (input.id, dirty)
                }
            }
            var collected: [UUID: Bool] = [:]
            for await (id, dirty) in group {
                if let dirty { collected[id] = dirty }
            }
            return collected
        }
        projectGitDirty = results
    }

    /// Send a commit-only follow-up into the selected thread. The prompt names
    /// the files recorded for that thread so the agent can avoid staging
    /// unrelated work.
    @discardableResult
    func commitFilesForThread(sessionId: String) async throws -> String {
        guard let summary = allSessionSummaries.first(where: { $0.id == sessionId })
            ?? threadStore.fetch(id: sessionId)?.toSummary() else {
            throw CommitFilesError.unknownThread
        }
        guard projects.contains(where: { $0.id == summary.projectId }) else {
            throw CommitFilesError.unknownProject
        }

        var seen = Set<String>()
        let changedFiles = threadStore.fetchFileEdits(sessionId: sessionId).compactMap { edit in
            seen.insert(edit.path).inserted ? edit.path : nil
        }

        let result = try await sendCrossProject(
            projectId: nil,
            threadId: sessionId,
            prompt: Self.threadCommitPrompt(changedFiles: changedFiles),
            permissionMode: .auto,
            waitForResponse: false,
            timeoutSeconds: 600,
            setupKind: HookSetupKind.commitPush
        )
        if let error = result.error { throw CommitFilesError.sendFailed(error) }
        return result.threadId
    }

    /// Start a commit-only thread for all current uncommitted project changes.
    /// Used by project rows and briefing cards.
    @discardableResult
    func commitAllChangesForProject(project: Project) async throws -> String {
        let result = try await sendCrossProject(
            projectId: project.id,
            threadId: nil,
            prompt: Self.projectCommitPrompt(projectName: project.name),
            permissionMode: .auto,
            waitForResponse: false,
            timeoutSeconds: 600,
            threadLabel: Self.manualCommitLabel,
            skipHooks: true,
            setupKind: HookSetupKind.commitPush
        )
        if let error = result.error { throw CommitFilesError.sendFailed(error) }
        return result.threadId
    }

    static func threadCommitPrompt(changedFiles: [String]) -> String {
        let fileList = changedFiles.isEmpty
            ? "(no recorded file edits — inspect this thread and the working tree, then commit only the files that belong to this thread)"
            : changedFiles.map { "- \($0)" }.joined(separator: "\n")

        return """
        Commit the files changed by this thread.

        Files changed by this thread:
        \(fileList)

        Steps:
        1. Inspect `git status` and the relevant diffs.
        2. Stage only the files that belong to this thread. Do not stage unrelated project changes.
        3. Create a local commit with a clear Conventional Commit message.
        4. Report the commit hash and the files committed.

        Do not push the commit unless the user explicitly asks for a push.
        Do not make further code changes beyond what is needed to commit these files.
        """
    }

    static func projectCommitPrompt(projectName: String) -> String {
        """
        Commit all current uncommitted changes for project `\(projectName)`.

        Steps:
        1. Inspect `git status` and the relevant diffs.
        2. Stage all modified, deleted, and untracked files that belong to the current project change set.
        3. Create a local commit with a clear Conventional Commit message.
        4. Report the commit hash and the files committed.

        If there are no uncommitted changes, report that clearly and do not create an empty commit.
        Do not push the commit unless the user explicitly asks for a push.
        Do not make further code changes beyond what is needed to commit the current changes.
        """
    }
}
