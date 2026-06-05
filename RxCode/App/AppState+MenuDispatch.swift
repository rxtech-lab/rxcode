import AppKit
import Foundation
import os
import RxCodeCore

/// Errors raised while dispatching a serialized `MenuActionCommand`.
enum MenuDispatchError: LocalizedError {
    case unknownProject
    case unknownThread
    case unresolvedBranch
    case invalidCustomCommand
    case invalidCustomURL
    case apiStatus(Int)
    case customActionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unknownProject: return "Couldn't find the project for this menu action."
        case .unknownThread: return "Couldn't find the thread for this menu action."
        case .unresolvedBranch: return "Couldn't determine the current branch."
        case .invalidCustomCommand: return "This custom menu item is missing its action configuration."
        case .invalidCustomURL: return "This custom menu item has an invalid URL."
        case .apiStatus(let code): return "The request failed with HTTP status \(code)."
        case .customActionFailed(let message): return message
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

        case .projectFixCI:
            let project = try requireProject(command.projectId)
            // Honor an explicit branch (briefing cards are per-branch); a generic
            // project menu passes nil and the fix resolves the current branch.
            let branch = command.branch.flatMap { $0.isEmpty ? nil : $0 }
            return MenuCommandResult(threadId: try await createCIFixForBranch(project: project, branch: branch))

        case .threadCodeReview:
            let sessionId = try requireSession(command.sessionId)
            return MenuCommandResult(threadId: try await createCodeReviewForThread(sessionId: sessionId))

        case .threadCommitFiles:
            let sessionId = try requireSession(command.sessionId)
            return MenuCommandResult(threadId: try await commitFilesForThread(sessionId: sessionId))

        case .threadStopCodeReview:
            let sessionId = try requireSession(command.sessionId)
            // Cancel the pending countdown and/or stop the running review thread.
            reviewScheduler.cancel(parentSessionKey: sessionId, reason: .contextMenu)
            return MenuCommandResult()

        case .custom:
            return try await dispatchCustomCommand(command)
        }
    }

    /// Run a user-defined custom menu command. The config arrives fully resolved
    /// (placeholders already substituted by `CustomMenuHook`), so this just
    /// performs the work: an HTTP request, or seeding a new / existing thread.
    private func dispatchCustomCommand(_ command: MenuActionCommand) async throws -> MenuCommandResult {
        guard let config = command.custom else { throw MenuDispatchError.invalidCustomCommand }
        switch config.kind {
        case .callAPI:
            try await performCustomAPICall(config)
            return MenuCommandResult()

        case .createThread:
            let project = try requireProject(command.projectId)
            let result = try await sendCrossProject(
                projectId: project.id,
                threadId: nil,
                prompt: config.message ?? "",
                waitForResponse: false
            )
            if let error = result.error { throw MenuDispatchError.customActionFailed(error) }
            return MenuCommandResult(threadId: result.threadId)

        case .continueThread:
            guard let sessionId = config.targetSessionId, !sessionId.isEmpty else {
                throw MenuDispatchError.unknownThread
            }
            let result = try await sendCrossProject(
                projectId: command.projectId,
                threadId: sessionId,
                prompt: config.message ?? "",
                waitForResponse: false
            )
            if let error = result.error { throw MenuDispatchError.customActionFailed(error) }
            return MenuCommandResult(threadId: result.threadId)
        }
    }

    /// Perform the configured HTTP request, throwing on a transport error or a
    /// non-2xx status so the failure surfaces in the menu error alert.
    private func performCustomAPICall(_ config: CustomMenuActionConfig) async throws {
        guard let urlString = config.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: urlString) else {
            throw MenuDispatchError.invalidCustomURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = (config.httpMethod ?? "GET").uppercased()
        for (name, value) in config.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = config.body, !body.isEmpty {
            request.httpBody = body.data(using: .utf8)
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MenuDispatchError.apiStatus(http.statusCode)
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
                    // Async commands (push + open PR, code review, …) block on real
                    // work, so show the hook loading dialog and keep it up until the
                    // operation finishes — mirroring mobile's action dialog.
                    if command.isAsync { self.hookProgressStatus = command.progressStatus }
                    defer { if command.isAsync { self.hookProgressStatus = nil } }
                    do {
                        let result = try await self.dispatchMenuCommand(command)
                        if let url = result.openURL { NSWorkspace.shared.open(url) }
                        if let threadId = result.threadId { onThread(threadId) }
                    } catch {
                        // Surface the failure to the user — not just the log — so a
                        // failed command (e.g. Create Pull Request) doesn't silently
                        // vanish with the loading dialog. Rendered by `HookUIModifier`.
                        self.logger.error("Menu command failed: \(error.localizedDescription, privacy: .public)")
                        self.hookErrorMessage = error.localizedDescription
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
