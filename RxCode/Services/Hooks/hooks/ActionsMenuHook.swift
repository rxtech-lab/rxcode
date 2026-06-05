#if os(macOS)
import Foundation
import RxCodeCore

/// Supplies the manual one-off action items for **both** the project and thread
/// context menus — Code Review, Commit, Create Pull Request — that used to be
/// hardcoded in the sidebar / briefing / chat-row menus. Routing them through
/// serializable `MenuItem`s means desktop and mobile render the same items, and
/// mobile can fetch them from the desktop over the relay.
///
/// One hook implements both `onProjectContextMenu` and `onThreadContextMenu`
/// since the two menus share the same "manual action" purpose. These are
/// `.command` actions (real work the desktop performs), not deep links: the
/// desktop dispatches them locally and mobile relays them back via
/// `executeMenuCommand`.
@MainActor
final class ActionsMenuHook: Hook {
    let hookID = "builtin.actionsMenu"

    // MARK: - Project menu

    func onProjectContextMenu(_ payload: ProjectContextMenuPayload, controller: any HookController) -> [MenuItem] {
        projectItems(for: payload.project, branch: payload.branch, controller: controller)
    }

    private func projectItems(for project: Project, branch: String?, controller: any HookController) -> [MenuItem] {
        var items: [MenuItem] = []
        // A branch-scoped menu (e.g. a briefing card) addresses `branch`; a
        // generic project menu addresses the current branch (carried as nil so
        // the dispatcher resolves it).
        let branchSuffix = branch.map { ".\($0)" } ?? ""

        // Code review for the branch (or the current branch when unscoped).
        items.append(MenuItem(
            id: "\(hookID).project.codeReview.\(project.id.uuidString)\(branchSuffix)",
            title: branch.map { String(localized: "Code Review for \($0)") }
                ?? String(localized: "Code Review for Current Branch"),
            systemImage: "checklist",
            action: .command(MenuActionCommand(kind: .projectCodeReview, projectId: project.id, branch: branch))
        ))

        // Commit all — only when the working tree has uncommitted changes.
        if controller.projectHasUncommittedChanges(project) {
            items.append(MenuItem(
                id: "\(hookID).project.commitAll.\(project.id.uuidString)",
                title: String(localized: "Commit All Changes"),
                systemImage: "checkmark.circle",
                action: .command(MenuActionCommand(kind: .projectCommitAll, projectId: project.id))
            ))
        }

        // Create PR — only when the repo is linked and has no open PR for the
        // tracked branch. The command carries `branch` so a briefing card opens a
        // PR for its own branch.
        if project.gitHubRepo != nil, !controller.projectHasOpenPullRequest(project, branch: branch) {
            items.append(MenuItem(
                id: "\(hookID).project.createPR.\(project.id.uuidString)\(branchSuffix)",
                title: String(localized: "Create Pull Request"),
                systemImage: "arrow.triangle.pull",
                action: .command(MenuActionCommand(kind: .projectCreatePullRequest, projectId: project.id, branch: branch, isAsync: true))
            ))
        }

        // Fix CI — only when GitHub Actions is failing for the branch (or current
        // branch when unscoped). Spawns a thread seeded with the failing run(s).
        if controller.projectCIIsFailing(project, branch: branch) {
            items.append(MenuItem(
                id: "\(hookID).project.fixCI.\(project.id.uuidString)\(branchSuffix)",
                title: String(localized: "Fix Failing CI"),
                systemImage: "wrench.and.screwdriver",
                action: .command(MenuActionCommand(kind: .projectFixCI, projectId: project.id, branch: branch))
            ))
        }

        return items
    }

    // MARK: - Thread menu

    func onThreadContextMenu(_ payload: ThreadContextMenuPayload, controller: any HookController) -> [MenuItem] {
        // A `[Code Review]` thread doesn't review or commit itself.
        if payload.session.threadLabel == AppState.manualCodeReviewLabel { return [] }

        var items: [MenuItem] = []

        // Stop an in-flight automatic review (countdown or running review thread).
        // Only shown while a review is actually pending/running for this thread.
        if controller.threadHasOngoingReview(sessionId: payload.session.id) {
            items.append(MenuItem(
                id: "\(hookID).thread.stopCodeReview.\(payload.session.id)",
                title: String(localized: "Stop Code Review"),
                systemImage: "stop.circle",
                role: .destructive,
                action: .command(MenuActionCommand(kind: .threadStopCodeReview, sessionId: payload.session.id))
            ))
        }

        items.append(MenuItem(
            id: "\(hookID).thread.codeReview.\(payload.session.id)",
            title: String(localized: "Code Review for this thread"),
            systemImage: "checklist",
            action: .command(MenuActionCommand(kind: .threadCodeReview, sessionId: payload.session.id))
        ))

        // Commit Files — only when the thread recorded file edits.
        if controller.threadHasFileChanges(sessionId: payload.session.id) {
            items.append(MenuItem(
                id: "\(hookID).thread.commitFiles.\(payload.session.id)",
                title: String(localized: "Commit Files"),
                systemImage: "checkmark.circle",
                action: .command(MenuActionCommand(kind: .threadCommitFiles, sessionId: payload.session.id))
            ))
        }

        return items
    }
}
#endif
