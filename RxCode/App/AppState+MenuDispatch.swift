import AppKit
import Foundation
import os
import RxCodeCore

/// Errors raised while dispatching a serialized `MenuActionCommand`.
enum MenuDispatchError: LocalizedError {
    case unknownProject
    case unknownThread
    case unresolvedBranch

    var errorDescription: String? {
        switch self {
        case .unknownProject: return "Couldn't find the project for this menu action."
        case .unknownThread: return "Couldn't find the thread for this menu action."
        case .unresolvedBranch: return "Couldn't determine the current branch."
        }
    }
}

/// Result of running a menu command, so callers (desktop tap or an inbound
/// mobile execute-action request) can navigate or open a URL afterward.
struct MenuCommandResult: Sendable {
    /// A spawned / affected thread id to navigate to, if any.
    var threadId: String?
    /// A URL to open (e.g. a freshly created pull request), if any.
    var openURL: URL?
}

extension AppState {
    // MARK: - Command dispatch (shared by desktop tap + mobile relay)

    /// Single entry point for every serialized `MenuActionCommand`. The desktop
    /// menu handler and the mobile execute-action request both route through
    /// here, so the work runs identically whichever side initiated it. Reuses the
    /// existing project/thread action methods.
    @discardableResult
    func dispatchMenuCommand(_ command: MenuActionCommand) async throws -> MenuCommandResult {
        switch command.kind {
        case .projectCommitAll:
            let project = try requireProject(command.projectId)
            return MenuCommandResult(threadId: try await commitAllChangesForProject(project: project))

        case .projectCreatePullRequest:
            let project = try requireProject(command.projectId)
            // Honor an explicit branch (briefing cards are per-branch); otherwise
            // resolve the project's current branch.
            if let branch = command.branch, !branch.isEmpty {
                return MenuCommandResult(openURL: try await createPullRequestForBranch(project: project, branch: branch))
            }
            return MenuCommandResult(openURL: try await createPullRequestForCurrentBranch(project: project))

        case .projectCodeReview:
            let project = try requireProject(command.projectId)
            let branch: String
            if let explicit = command.branch, !explicit.isEmpty {
                branch = explicit
            } else if let current = await GitHelper.currentBranch(at: project.path), !current.isEmpty {
                branch = current
            } else {
                throw MenuDispatchError.unresolvedBranch
            }
            return MenuCommandResult(threadId: try await createCodeReviewForBranch(project: project, branch: branch))

        case .threadCodeReview:
            let sessionId = try requireSession(command.sessionId)
            return MenuCommandResult(threadId: try await createCodeReviewForThread(sessionId: sessionId))

        case .threadCommitFiles:
            let sessionId = try requireSession(command.sessionId)
            return MenuCommandResult(threadId: try await commitFilesForThread(sessionId: sessionId))
        }
    }

    private func requireProject(_ id: UUID?) throws -> Project {
        guard let id, let project = projects.first(where: { $0.id == id }) else {
            throw MenuDispatchError.unknownProject
        }
        return project
    }

    private func requireSession(_ id: String?) throws -> String {
        guard let id, !id.isEmpty else { throw MenuDispatchError.unknownThread }
        return id
    }

    // MARK: - Deep links (desktop-local sheets / setup flows)

    /// Map a `rxcode://menu/…` deep link to the desktop's existing sheet / setup
    /// requests. Mobile maps the same links to its own sheets; the desktop reuses
    /// the request properties the inline menus already set.
    func handleMenuDeepLink(_ parsed: MenuDeepLink.Parsed) {
        guard let projectId = parsed.projectId,
              let project = projects.first(where: { $0.id == projectId }) else { return }

        switch parsed.action {
        case MenuDeepLink.secretsSetup:
            secretsSetupRequest = SecretsSetupRequest(
                repoFullName: project.gitHubRepo,
                projectPath: project.path,
                filename: nil
            )
        case MenuDeepLink.secretsDownload:
            secretsDownloadRequest = project
        case MenuDeepLink.docsSetup:
            docsSetupRequest = DocsSetupRequest(projectId: project.id, repoFullName: project.gitHubRepo)
        case MenuDeepLink.docsSearch:
            docsSearchRequest = UUID()
        case MenuDeepLink.releaseSetup:
            releaseSetupRequest = ReleaseSetupRequest(projectId: project.id, repoFullName: project.gitHubRepo)
        case MenuDeepLink.releaseCreate:
            releaseCreateRequest = project
        case MenuDeepLink.ciSetup:
            ciSetupRequest = CISetupRequest(repoFullName: project.gitHubRepo, projectPath: project.path)
        default:
            break
        }
    }

    // MARK: - Desktop menu action handler

    /// Convenience handler that selects the spawned/affected thread in `window`
    /// after a command runs — preserving the pre-migration behavior where code
    /// review / commit actions navigated to the new thread.
    func desktopMenuActionHandler(navigatingIn window: WindowState) -> MenuActionHandler {
        desktopMenuActionHandler { [weak self] threadId in
            self?.selectSession(id: threadId, in: window)
        }
    }

    /// The `MenuActionHandler` to install (`.menuActionHandler(...)`) on desktop
    /// context menus so a tapped `MenuItem` dispatches locally: commands run
    /// through `dispatchMenuCommand`; deep links open their local sheet. `onThread`
    /// is invoked with a spawned thread id so the caller can navigate if it wants.
    func desktopMenuActionHandler(onThread: @escaping (String) -> Void = { _ in }) -> MenuActionHandler {
        MenuActionHandler { [weak self] action in
            guard let self else { return }
            switch action {
            case .command(let command):
                Task { @MainActor in
                    do {
                        let result = try await self.dispatchMenuCommand(command)
                        if let url = result.openURL { NSWorkspace.shared.open(url) }
                        if let threadId = result.threadId { onThread(threadId) }
                    } catch {
                        self.logger.error("Menu command failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            case .deepLink(let url):
                if let parsed = MenuDeepLink.parse(url) {
                    self.handleMenuDeepLink(parsed)
                }
            }
        }
    }
}
