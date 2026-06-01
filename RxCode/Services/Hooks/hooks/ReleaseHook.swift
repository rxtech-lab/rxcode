#if os(macOS)
import Foundation
import os
import RxCodeCore
import SwiftUI

/// Surfaces a "set up release" banner on the new-chat screen when the project's
/// GitHub repo has no release workflow configured, and — when the user accepts —
/// injects the release skill into that chat's system prompt so the agent wires
/// up the `.releaserc` + CI workflow. Mirrors `DocsHook`.
@MainActor
final class ReleaseHook: Hook {
    let hookID = "builtin.release"
    private let logger = Logger(subsystem: "com.claudework", category: "ReleaseHook")

    /// Stable banner id for a repo, distinct from the docs/secrets banners so all
    /// can coexist, e.g. repo "owner/github-pm" → "github-pm-new-project-release".
    private func bannerID(for project: Project) -> String? {
        guard let repo = project.gitHubRepo else { return nil }
        let repoSlug = repo.split(separator: "/").last.map(String.init) ?? repo
        return "\(repoSlug)-new-project-release"
    }

    func onProjectDelete(_ payload: ProjectDeletePayload, controller: any HookController) async -> HookOutcome {
        guard let bannerID = bannerID(for: payload.project) else { return .ignored }
        controller.clearBannerDismissal(id: bannerID)
        controller.dismissBanner(id: bannerID, in: .newProject)
        return .proceed
    }

    /// On each new chat, check whether the repo has a release workflow. If not,
    /// surface the "set up release" banner above the input box. Passive — never
    /// blocks.
    func onProjectNewChatStart(_ payload: NewChatStartPayload, controller: any HookController) async -> HookOutcome {
        guard let project = controller.project(for: payload.projectId) else { return .ignored }
        guard let repo = project.gitHubRepo else { return .ignored }

        let bannerID = bannerID(for: project) ?? "\(repo)-new-project-release"
        if controller.isBannerDismissed(id: bannerID) {
            logger.debug("[Hook] onProjectNewChatStart: banner \(bannerID, privacy: .public) is in the user-dismissed set — not showing (release status not checked)")
            return .ignored
        }

        guard let configured = await controller.releaseConfigured(repoFullName: repo) else {
            // Inconclusive (signed out / offline / failed) — leave the banner
            // untouched rather than flashing a stale prompt.
            return .ignored
        }
        guard !Task.isCancelled else { return .ignored }

        if configured {
            // Repo already has releases set up — make sure no stale banner lingers.
            controller.dismissBanner(id: bannerID, in: .newProject)
            return .ignored
        }

        logger.debug("[Hook] repo \(repo, privacy: .public) has no release workflow — showing setup banner \(bannerID, privacy: .public)")
        controller.showBanner(in: .newProject, position: .aboveInputBox, id: bannerID, projectId: project.id) {
            ReleaseSetupBanner(repo: repo) {
                controller.markBannerDismissed(id: bannerID, in: .newProject)
            }
        }
        return .proceed
    }

    /// When the user accepted the banner, a release-setup chat was started for
    /// this project. Inject the release skill into the system prompt for that one
    /// chat so the agent knows how to set everything up.
    func onSessionStart(_ payload: SessionStartPayload, controller: any HookController) async -> HookOutcome {
        guard let skill = controller.consumePendingReleaseSetupSkill(projectId: payload.project.id) else {
            return .ignored
        }
        // Remember this session so `afterSessionEnd` knows to re-check the release
        // status once the agent is done and drop the banner if it's now set up.
        controller.markSetupSession(kind: HookSetupKind.release, sessionKey: payload.sessionKey)
        logger.debug("[Hook] injecting release skill into session for project \(payload.project.id.uuidString, privacy: .public)")
        return .output(skill)
    }

    /// On every completed turn of a release-setup chat (started from the banner),
    /// re-fetch the latest release setup result and dismiss the banner if the repo
    /// now has a release workflow. The session marker is *peeked*, not consumed —
    /// the release skill asks the user a question first, so setup spans multiple
    /// turns; we keep re-checking until it's confirmed, then stop tracking.
    func afterSessionEnd(_ payload: SessionEndPayload, controller: any HookController) async -> HookOutcome {
        guard controller.isSetupSession(kind: HookSetupKind.release, sessionKey: payload.sessionKey) else {
            logger.debug("[Hook] afterSessionEnd: session \(payload.sessionKey, privacy: .public) is not a release-setup session — ignoring")
            return .ignored
        }
        guard payload.reason == .completed, !payload.turnDidError else {
            logger.debug("[Hook] afterSessionEnd: session \(payload.sessionKey, privacy: .public) reason=\(String(describing: payload.reason), privacy: .public) turnDidError=\(payload.turnDidError, privacy: .public) — not a clean completion, keeping marker")
            return .ignored
        }
        guard let repo = payload.project.gitHubRepo else {
            logger.debug("[Hook] afterSessionEnd: project \(payload.project.id.uuidString, privacy: .public) has no gitHubRepo — clearing marker")
            controller.clearSetupSession(kind: HookSetupKind.release, sessionKey: payload.sessionKey)
            return .ignored
        }

        let bannerID = bannerID(for: payload.project) ?? "\(repo)-new-project-release"
        logger.debug("[Hook] afterSessionEnd: re-checking release status for \(repo, privacy: .public), bannerID=\(bannerID, privacy: .public)")

        guard let configured = await controller.releaseConfigured(repoFullName: repo) else {
            // Inconclusive (signed out / offline / failed) — keep the marker so the
            // next completed turn re-checks.
            logger.debug("[Hook] afterSessionEnd: releaseConfigured inconclusive (nil) for \(repo, privacy: .public) — keeping marker + banner, will re-check next turn")
            return .ignored
        }
        guard configured else {
            // Setup isn't done yet (e.g. the agent just asked which workflow to
            // use). Keep tracking and re-check after the next turn.
            logger.debug("[Hook] release-setup turn ended but repo \(repo, privacy: .public) is not yet managed — keeping banner")
            return .ignored
        }

        logger.debug("[Hook] release now configured (managed) for \(repo, privacy: .public) — dismissing banner \(bannerID, privacy: .public)")
        controller.clearSetupSession(kind: HookSetupKind.release, sessionKey: payload.sessionKey)
        controller.dismissBanner(id: bannerID, in: .newProject)
        return .proceed
    }
}
#endif
