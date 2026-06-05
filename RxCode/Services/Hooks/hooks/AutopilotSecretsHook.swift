#if os(macOS)
import Foundation
import os
import RxCodeCore
import SwiftUI

/// Integrates the IDE with autopilot's encrypted secrets. Two behaviours:
/// - On repository add (including clones — the clone path now also fires
///   `onRepositoryAdded`), check the autopilot secrets endpoint for the
///   project's GitHub repo. If any environments exist, let the user pick one in
///   a loading dialog, then download + decrypt its files into the project
///   folder. Conflicting local files are only overwritten after confirmation.
/// - On new chat, surface a banner when the project's local `.env*` files
///   aren't backed up to autopilot (see `onProjectNewChatStart`).
@MainActor
final class AutopilotSecretsHook: Hook {
    let hookID = "builtin.autopilot"
    private let logger = Logger(subsystem: "com.claudework", category: "AutopilotHook")

    func onRepositoryAdded(_ payload: RepositoryPayload, controller: any HookController) async -> HookOutcome {
        await run(project: payload.project, controller: controller)
    }

    func onThreadContextMenu(_ payload: ThreadContextMenuPayload, controller: any HookController) -> [MenuItem] {
        menuItems(for: payload.project, locale: payload.locale, controller: controller)
    }

    func onProjectContextMenu(_ payload: ProjectContextMenuPayload, controller: any HookController) -> [MenuItem] {
        menuItems(for: payload.project, locale: payload.locale, controller: controller)
    }

    private func menuItems(for project: Project, locale: String?, controller: any HookController) -> [MenuItem] {
        guard project.gitHubRepo != nil else { return [] }
        if controller.projectHasSecrets(project) {
            return [
                MenuItem(
                    id: "\(hookID).download.\(project.id.uuidString)",
                    title: MenuLocalizer.string("Download Secret", locale: locale),
                    systemImage: "key.fill",
                    action: .deepLink(MenuDeepLink.url(action: MenuDeepLink.secretsDownload, projectId: project.id))
                )
            ]
        }

        return [
            MenuItem(
                id: "\(hookID).setup.\(project.id.uuidString)",
                title: MenuLocalizer.string("Set Up Secrets", locale: locale),
                systemImage: "key.fill",
                action: .deepLink(MenuDeepLink.url(action: MenuDeepLink.secretsSetup, projectId: project.id))
            )
        ]
    }

    /// Stable, readable banner id for a repo, used both as the banner key and the
    /// persisted "dismissed" key, e.g. repo "owner/github-pm" →
    /// "github-pm-new-project-autopilot". Returns nil when the project has no repo.
    private func bannerID(for project: Project) -> String? {
        guard let repo = project.gitHubRepo else { return nil }
        let repoSlug = repo.split(separator: "/").last.map(String.init) ?? repo
        return "\(repoSlug)-new-project-autopilot"
    }

    /// When a project is removed, forget any persisted dismissal of its banner so
    /// re-adding the project surfaces the banner again.
    func onProjectDelete(_ payload: ProjectDeletePayload, controller: any HookController) async -> HookOutcome {
        guard let bannerID = bannerID(for: payload.project) else { return .ignored }
        logger.debug("[Hook] onProjectDelete: clearing dismissal for banner \(bannerID, privacy: .public)")
        controller.clearBannerDismissal(id: bannerID)
        controller.dismissBanner(id: bannerID, in: .newProject)
        return .proceed
    }

    /// On each new chat, check whether the project's local `.env*` files are
    /// backed up to autopilot. If the repo has no secrets at all, or a detected
    /// `.env*` file is missing from every environment, surface a banner above
    /// the input box prompting the user to set it up. This is a passive check —
    /// it never shows the modal loading dialog.
    func onProjectNewChatStart(_ payload: NewChatStartPayload, controller: any HookController) async -> HookOutcome {
        logger.debug("[Hook] onProjectNewChatStart fired: projectId=\(payload.projectId.uuidString, privacy: .public) sessionKey=\(payload.sessionKey, privacy: .public)")
        guard let project = controller.project(for: payload.projectId) else {
            logger.debug("[Hook] onProjectNewChatStart: no project for id \(payload.projectId.uuidString, privacy: .public) — bailing")
            return .ignored
        }
        guard let repo = project.gitHubRepo else {
            logger.debug("[Hook] onProjectNewChatStart: project \(project.name, privacy: .public) has no gitHubRepo — bailing")
            return .ignored
        }

        let bannerID = bannerID(for: project) ?? "\(repo)-new-project-autopilot"

        // Respect a prior user dismissal — don't resurface a banner they closed.
        if controller.isBannerDismissed(id: bannerID) {
            logger.debug("[Hook] onProjectNewChatStart: banner \(bannerID, privacy: .public) was dismissed by the user — not showing")
            return .ignored
        }

        let detected = DetectedEnv.scan(directory: project.path)
        logger.debug("[Hook] onProjectNewChatStart: repo=\(repo, privacy: .public) path=\(project.path, privacy: .public) detectedEnvFiles=\(detected.map(\.filename).joined(separator: ","), privacy: .public)")
        guard !detected.isEmpty else {
            logger.debug("[Hook] onProjectNewChatStart: no local .env* files detected — dismissing banner \(bannerID, privacy: .public)")
            controller.dismissBanner(id: bannerID, in: .newProject)
            return .ignored
        }

        let path = project.path
        guard let environments = await controller.secretEnvironments(repoFullName: repo) else {
            // The check failed or was cancelled (e.g. the user switched chats
            // mid-flight). Leave the banner untouched rather than flashing a
            // stale "back up secrets" banner off an inconclusive result.
            logger.debug("[Hook] onProjectNewChatStart: environments check inconclusive — leaving banner untouched")
            return .ignored
        }
        // Bail if this run was superseded (chat switched) so a cancelled task
        // never mutates the banner the fresh task is responsible for.
        guard !Task.isCancelled else {
            logger.debug("[Hook] onProjectNewChatStart: task cancelled after environments fetch — bailing")
            return .ignored
        }
        logger.debug("[Hook] onProjectNewChatStart: autopilot environments count=\(environments.count, privacy: .public) names=\(environments.map(\.label).joined(separator: ","), privacy: .public)")
        if environments.isEmpty {
            logger.debug("[Hook] onProjectNewChatStart: repo has no environments — showing 'back up secrets' banner \(bannerID, privacy: .public)")
            controller.showBanner(in: .newProject, position: .aboveInputBox, id: bannerID, projectId: project.id) {
                SecretsEnvBanner(repo: repo, projectPath: path, missingFile: nil) {
                    controller.markBannerDismissed(id: bannerID, in: .newProject)
                }
            }
            return .proceed
        }

        // Surface the first local file that isn't backed up anywhere.
        var missing: String?
        for env in detected {
            let exists = await controller.secretFileExists(repoFullName: repo, filename: env.filename)
            logger.debug("[Hook] onProjectNewChatStart: secretFileExists(\(env.filename, privacy: .public)) = \(exists, privacy: .public)")
            if !exists {
                missing = env.filename
                break
            }
        }

        // Re-check cancellation: the per-file lookups above are async, so a chat
        // switch could have superseded this run while they were in flight.
        guard !Task.isCancelled else {
            logger.debug("[Hook] onProjectNewChatStart: task cancelled after file checks — bailing")
            return .ignored
        }

        if let missing {
            logger.debug("[Hook] onProjectNewChatStart: \(missing, privacy: .public) is NOT backed up — showing banner \(bannerID, privacy: .public)")
            controller.showBanner(in: .newProject, position: .aboveInputBox, id: bannerID, projectId: project.id) {
                SecretsEnvBanner(repo: repo, projectPath: path, missingFile: missing) {
                    controller.markBannerDismissed(id: bannerID, in: .newProject)
                }
            }
        } else {
            logger.debug("[Hook] onProjectNewChatStart: all detected .env files are backed up — dismissing banner \(bannerID, privacy: .public)")
            controller.dismissBanner(id: bannerID, in: .newProject)
        }
        return .proceed
    }

    private func run(project: Project, controller: any HookController) async -> HookOutcome {
        guard let repo = project.gitHubRepo else { return .ignored }
        // Always dismiss the dialog, even on early return / thrown error.
        defer { controller.endProgress() }

        controller.beginProgress("hook.secrets.checking")
        let environments = await controller.secretEnvironments(repoFullName: repo) ?? []
        guard !environments.isEmpty else { return .ignored }

        // Always show the picker so the user explicitly chooses an environment.
        controller.endProgress()
        guard let env = await controller.requestChoice(
            title: "hook.secrets.pickEnv",
            choices: environments
        ) else { return .ignored }

        do {
            controller.beginProgress("hook.secrets.downloading")
            let files = try await controller.fetchSecrets(repoFullName: repo, env: env)

            // Detect files that would clobber something already in the folder.
            let conflicts = files
                .map(\.filename)
                .filter { FileManager.default.fileExists(atPath: (project.path as NSString).appendingPathComponent($0)) }

            var overwrite = false
            if !conflicts.isEmpty {
                controller.endProgress()
                overwrite = await controller.requestConfirmation(
                    title: "hook.secrets.overwriteConfirm",
                    detail: conflicts.joined(separator: ", ")
                )
                controller.beginProgress("hook.secrets.downloading")
            }

            let written = try controller.writeSecrets(files, toPath: project.path, overwrite: overwrite)
            logger.info("Downloaded \(written.count) secret file(s) for \(repo)")
            return .proceed
        } catch {
            logger.error("Secret auto-download failed for \(repo): \(error.localizedDescription)")
            return .output("Secret download failed: \(error.localizedDescription)", isError: true)
        }
    }
}
#endif
