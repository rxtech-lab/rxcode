#if os(macOS)
import Foundation
import os
import RxCodeCore
import SwiftUI

/// When a repository is added to the IDE (including clones — the clone path now
/// also fires `onRepositoryAdded`), check the autopilot secrets endpoint for the
/// project's GitHub repo. If any environments exist, let the user pick one in a
/// loading dialog, then download + decrypt its files into the project folder.
/// Conflicting local files are only overwritten after an explicit confirmation.
@MainActor
final class SecretsAutoDownloadHook: Hook {
    let hookID = "builtin.secretsAutoDownload"
    private let logger = Logger(subsystem: "com.claudework", category: "SecretsAutoDownloadHook")

    func onRepositoryAdded(_ payload: RepositoryPayload, controller: any HookController) async -> HookOutcome {
        await run(project: payload.project, controller: controller)
    }

    private func run(project: Project, controller: any HookController) async -> HookOutcome {
        guard let repo = project.gitHubRepo else { return .ignored }
        // Always dismiss the dialog, even on early return / thrown error.
        defer { controller.endProgress() }

        controller.beginProgress("hook.secrets.checking")
        let environments = await controller.secretEnvironments(repoFullName: repo)
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
