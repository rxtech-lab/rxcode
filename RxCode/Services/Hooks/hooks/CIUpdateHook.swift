#if os(macOS)
import Foundation
import os
import RxCodeCore
import SwiftUI

/// Surfaces a "set up CI auto-update" banner on the new-chat screen when the
/// project has local `.github/workflows/*.yml|yaml` files but its repo isn't yet
/// watched for CI auto-updates. Passive — never blocks the chat. Mirrors
/// `DocsHook` / `AutopilotHook`.
@MainActor
final class CIUpdateHook: Hook {
    let hookID = "builtin.ciupdate"
    private let logger = Logger(subsystem: "com.claudework", category: "CIUpdateHook")

    /// Stable banner id for a repo, distinct from the secrets/docs banners so all
    /// can coexist above the input box, e.g. repo "owner/github-pm" →
    /// "github-pm-new-project-ci-update".
    private func bannerID(for project: Project) -> String? {
        guard let repo = project.gitHubRepo else { return nil }
        let repoSlug = repo.split(separator: "/").last.map(String.init) ?? repo
        return "\(repoSlug)-new-project-ci-update"
    }

    func onProjectDelete(_ payload: ProjectDeletePayload, controller: any HookController) async -> HookOutcome {
        guard let bannerID = bannerID(for: payload.project) else { return .ignored }
        controller.clearBannerDismissal(id: bannerID)
        controller.dismissBanner(id: bannerID, in: .newProject)
        return .proceed
    }

    /// On each new chat, if the project has local workflow files and the repo
    /// isn't watched, surface the setup banner above the input box.
    func onProjectNewChatStart(_ payload: NewChatStartPayload, controller: any HookController) async -> HookOutcome {
        guard let project = controller.project(for: payload.projectId) else { return .ignored }
        guard let repo = project.gitHubRepo else { return .ignored }

        let bannerID = bannerID(for: project) ?? "\(repo)-new-project-ci-update"
        if controller.isBannerDismissed(id: bannerID) { return .ignored }

        // Local gate first: no workflow files → nothing to keep updated.
        let detected = DetectedWorkflow.scan(directory: project.path)
        guard !detected.isEmpty else {
            controller.dismissBanner(id: bannerID, in: .newProject)
            return .ignored
        }

        guard let isWatched = await controller.ciRepoIsWatched(repoFullName: repo) else {
            // Inconclusive (signed out / offline / failed) — leave the banner
            // untouched rather than flashing a stale prompt.
            return .ignored
        }
        guard !Task.isCancelled else { return .ignored }

        if isWatched {
            // Already watched — make sure no stale banner lingers.
            controller.dismissBanner(id: bannerID, in: .newProject)
            return .ignored
        }

        let path = project.path
        let count = detected.count
        logger.debug("[Hook] repo \(repo, privacy: .public) has \(count, privacy: .public) workflow file(s) and isn't watched — showing CI banner \(bannerID, privacy: .public)")
        controller.showBanner(in: .newProject, position: .aboveInputBox, id: bannerID, projectId: project.id) {
            CIUpdateBanner(repo: repo, projectPath: path, workflowCount: count) {
                controller.markBannerDismissed(id: bannerID, in: .newProject)
            }
        }
        return .proceed
    }
}
#endif
