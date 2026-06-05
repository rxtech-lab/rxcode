#if os(macOS)
import Foundation
import os
import RxCodeCore
import SwiftUI

/// Surfaces a "set up docs" banner on the new-chat screen when the project's
/// GitHub repo has no documentation indexed in the docs service, and — when the
/// user accepts — injects the docs-publishing skill into that chat's system
/// prompt so the agent wires up CI doc uploads. Mirrors `AutopilotHook`.
@MainActor
final class AutopilotDocsHook: Hook {
    let hookID = "builtin.docs"
    private let logger = Logger(subsystem: "com.claudework", category: "DocsHook")

    /// Stable banner id for a repo, distinct from the secrets banner so both can
    /// coexist, e.g. repo "owner/github-pm" → "github-pm-new-project-docs".
    private func bannerID(for project: Project) -> String? {
        guard let repo = project.gitHubRepo else { return nil }
        let repoSlug = repo.split(separator: "/").last.map(String.init) ?? repo
        return "\(repoSlug)-new-project-docs"
    }

    func onThreadContextMenu(_ payload: ThreadContextMenuPayload, controller: any HookController) -> [MenuItem] {
        menuItems(for: payload.project, controller: controller)
    }

    func onProjectContextMenu(_ payload: ProjectContextMenuPayload, controller: any HookController) -> [MenuItem] {
        menuItems(for: payload.project, controller: controller)
    }

    private func menuItems(for project: Project, controller: any HookController) -> [MenuItem] {
        guard project.gitHubRepo != nil else { return [] }
        // Docs search was removed from the menu. Once a repo's docs are indexed
        // there's nothing to do here; otherwise offer to set them up.
        guard !controller.projectHasDocs(project) else { return [] }
        return [
            MenuItem(
                id: "\(hookID).setup.\(project.id.uuidString)",
                title: String(localized: "Set Up Docs"),
                systemImage: "books.vertical.fill",
                action: .deepLink(MenuDeepLink.url(action: MenuDeepLink.docsSetup, projectId: project.id))
            )
        ]
    }

    func onProjectDelete(_ payload: ProjectDeletePayload, controller: any HookController) async -> HookOutcome {
        guard let bannerID = bannerID(for: payload.project) else { return .ignored }
        controller.clearBannerDismissal(id: bannerID)
        controller.dismissBanner(id: bannerID, in: .newProject)
        return .proceed
    }

    /// On each new chat, check whether the repo has docs. If not, surface the
    /// "set up docs" banner above the input box. Passive — never blocks.
    func onProjectNewChatStart(_ payload: NewChatStartPayload, controller: any HookController) async -> HookOutcome {
        guard let project = controller.project(for: payload.projectId) else { return .ignored }
        guard let repo = project.gitHubRepo else { return .ignored }

        let bannerID = bannerID(for: project) ?? "\(repo)-new-project-docs"
        if controller.isBannerDismissed(id: bannerID) {
            logger.debug("[Hook] onProjectNewChatStart: banner \(bannerID, privacy: .public) is in the user-dismissed set — not showing (docs status not checked)")
            return .ignored
        }

        guard let hasDocs = await controller.docsIndexed(repoFullName: repo) else {
            // Inconclusive (signed out / offline / failed) — leave the banner
            // untouched rather than flashing a stale prompt.
            return .ignored
        }
        guard !Task.isCancelled else { return .ignored }

        if hasDocs {
            // Repo already has docs — make sure no stale banner lingers.
            controller.dismissBanner(id: bannerID, in: .newProject)
            return .ignored
        }

        logger.debug("[Hook] repo \(repo, privacy: .public) has no docs — showing setup banner \(bannerID, privacy: .public)")
        controller.showBanner(in: .newProject, position: .aboveInputBox, id: bannerID, projectId: project.id) {
            DocsSetupBanner(repo: repo) {
                controller.markBannerDismissed(id: bannerID, in: .newProject)
            }
        }
        return .proceed
    }

    /// When the user accepted the banner, a docs-setup chat was started for this
    /// project. Inject the docs-publishing skill into the system prompt for that
    /// one chat so the agent knows how to set everything up.
    func onSessionStart(_ payload: SessionStartPayload, controller: any HookController) async -> HookOutcome {
        guard let skill = controller.consumePendingDocsSetupSkill(projectId: payload.project.id) else {
            return .ignored
        }
        // Remember this session so `afterSessionEnd` knows to re-check the docs
        // status once the agent is done and drop the banner if docs are now indexed.
        controller.markSetupSession(kind: HookSetupKind.docs, sessionKey: payload.sessionKey)
        logger.debug("[Hook] injecting docs-publishing skill into session for project \(payload.project.id.uuidString, privacy: .public)")
        return .output(skill)
    }

    /// On every completed turn of a docs-setup chat (started from the banner),
    /// re-fetch the latest docs status and dismiss the banner if the repo now has
    /// docs indexed. The session marker is *peeked*, not consumed — docs setup can
    /// span multiple turns; we keep re-checking until it's confirmed, then stop
    /// tracking.
    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        guard controller.isSetupSession(kind: HookSetupKind.docs, sessionKey: payload.sessionKey) else {
            logger.debug("[Hook] afterSessionEnd: session \(payload.sessionKey, privacy: .public) is not a docs-setup session — ignoring")
            return .ignored
        }
        guard payload.reason == .completed, !payload.turnDidError else {
            logger.debug("[Hook] afterSessionEnd: session \(payload.sessionKey, privacy: .public) reason=\(String(describing: payload.reason), privacy: .public) turnDidError=\(payload.turnDidError, privacy: .public) — not a clean completion, keeping marker")
            return .ignored
        }
        guard let repo = payload.project.gitHubRepo else {
            logger.debug("[Hook] afterSessionEnd: project \(payload.project.id.uuidString, privacy: .public) has no gitHubRepo — clearing marker")
            controller.clearSetupSession(kind: HookSetupKind.docs, sessionKey: payload.sessionKey)
            return .ignored
        }

        let bannerID = bannerID(for: payload.project) ?? "\(repo)-new-project-docs"
        logger.debug("[Hook] afterSessionEnd: re-checking docs status for \(repo, privacy: .public), bannerID=\(bannerID, privacy: .public)")

        guard let hasDocs = await controller.docsIndexed(repoFullName: repo) else {
            // Inconclusive (signed out / offline / failed) — keep the marker so the
            // next completed turn re-checks.
            logger.debug("[Hook] afterSessionEnd: docsIndexed inconclusive (nil) for \(repo, privacy: .public) — keeping marker + banner, will re-check next turn")
            return .ignored
        }
        guard hasDocs else {
            // Setup isn't done yet — keep tracking and re-check after the next turn.
            logger.debug("[Hook] docs-setup turn ended but repo \(repo, privacy: .public) is not yet registered — keeping banner")
            return .ignored
        }

        logger.debug("[Hook] docs now set up (registered) for \(repo, privacy: .public) — dismissing banner \(bannerID, privacy: .public)")
        controller.clearSetupSession(kind: HookSetupKind.docs, sessionKey: payload.sessionKey)
        controller.dismissBanner(id: bannerID, in: .newProject)
        return .proceed
    }
}
#endif
