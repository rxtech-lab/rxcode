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
final class DocsHook: Hook {
    let hookID = "builtin.docs"
    private let logger = Logger(subsystem: "com.claudework", category: "DocsHook")

    /// Stable banner id for a repo, distinct from the secrets banner so both can
    /// coexist, e.g. repo "owner/github-pm" → "github-pm-new-project-docs".
    private func bannerID(for project: Project) -> String? {
        guard let repo = project.gitHubRepo else { return nil }
        let repoSlug = repo.split(separator: "/").last.map(String.init) ?? repo
        return "\(repoSlug)-new-project-docs"
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
        if controller.isBannerDismissed(id: bannerID) { return .ignored }

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
        logger.debug("[Hook] injecting docs-publishing skill into session for project \(payload.project.id.uuidString, privacy: .public)")
        return .output(skill)
    }
}
#endif
