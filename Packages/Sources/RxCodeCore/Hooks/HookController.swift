import Foundation
import SwiftUI

/// The capabilities a hook may use to act on the thread / IDE. This is the
/// single seam between hooks and the host app (`AppState`): hooks never touch
/// app internals directly, only this surface. It is also the vocabulary a
/// future out-of-process plugin host would expose over RPC.
///
/// `@MainActor` because everything it drives — the message store, the
/// notification center, the thread database — already runs on the main actor.
@MainActor
public protocol HookController: AnyObject {
    // MARK: Chat cards

    /// Insert a synthetic "running" tool-call card (spinner) into a session's
    /// message list and return a handle to complete it later. Streams to paired
    /// mobile devices automatically.
    func insertCard(sessionKey: String, toolName: String, input: [String: JSONValue]) -> HookCardHandle

    /// Fill in a previously-inserted card's result, flipping the spinner to a
    /// success/error badge.
    func completeCard(_ handle: HookCardHandle, sessionKey: String, result: String, isError: Bool)

    /// Persist a session's "last hook" so the synthetic card can be rebuilt on
    /// reload (hook cards never reach the CLI transcript).
    func persistHookStatus(sessionKey: String, toolId: String, name: String, trigger: String, output: String, isError: Bool)

    /// Enabled user hook profiles for a project + trigger, loading from disk on
    /// first access.
    func enabledHookProfiles(projectId: UUID, trigger: HookTrigger) async -> [HookProfile]

    // MARK: Queries

    var notificationsEnabled: Bool { get }
    var isAppActive: Bool { get }

    func project(for id: UUID) -> Project?
    /// The display title of a session (from its summary), if known.
    func sessionTitle(sessionId: String) -> String?
    /// First-sentence fallback body for a response-complete notification.
    func responseNotificationFallback(from responseText: String) -> String
    /// Optionally generate an AI summary of the response for a notification body.
    /// Returns nil when summaries are disabled or the session summary is unknown.
    func responseNotificationSummary(responseText: String, sessionId: String) async -> String?

    // MARK: Notifications

    func postResponseComplete(title: String, body: String, projectId: UUID, sessionId: String, postLocalBanner: Bool) async
    func postQuestionNeeded(projectName: String?, projectId: UUID?, sessionId: String?) async
    func postPermissionNeeded(toolName: String, projectName: String?, projectId: UUID?, sessionId: String?) async
    func postMCPDisconnected(name: String, error: String?) async
    func postCIFailed(projectName: String?, projectId: UUID?, failingWorkflowNames: [String]) async
    func postRemoteConfigChanged(title: String, body: String) async

    // MARK: Interactive UI

    /// Show the hook loading dialog with an initial status line (e.g. while an
    /// async hook does its work). Idempotent — calling again just updates text.
    func beginProgress(_ status: LocalizedStringKey)
    /// Update the status line of the visible loading dialog.
    func updateProgress(_ status: LocalizedStringKey)
    /// Dismiss the loading dialog.
    func endProgress()

    /// Present a single-choice picker and suspend until the user picks (returns
    /// the chosen `HookChoice.id`) or cancels (returns `nil`).
    func requestChoice(title: LocalizedStringKey, choices: [HookChoice]) async -> String?

    /// Present a confirm/cancel dialog; returns `true` if confirmed. `detail`
    /// carries dynamic, non-localizable text (e.g. a list of filenames).
    func requestConfirmation(title: LocalizedStringKey, detail: String?) async -> Bool

    // MARK: Banners

    /// Show (or replace) a hook-supplied banner in a screen surface. The hook
    /// owns the entire view — including any button and its action — so banners
    /// are not limited to a fixed shape. `id` is a stable key: showing again
    /// with the same `(surface, id)` replaces the existing banner. Prefer the
    /// `@ViewBuilder` convenience below over calling this directly.
    ///
    /// `projectId` scopes the banner to one project: the host only renders it
    /// while that project is open, so switching projects hides it automatically.
    /// Pass `nil` for a banner that should show regardless of the open project.
    func showBanner(_ content: AnyView, id: String, projectId: UUID?, in surface: HookBannerSurface, position: HookBannerPosition)
    /// Remove a previously-shown banner. No-op if it isn't currently shown.
    func dismissBanner(id: String, in surface: HookBannerSurface)

    /// Whether the user previously dismissed the banner with this `id`. The flag
    /// is persisted across launches, so a hook should check this before showing a
    /// banner the user has already closed.
    func isBannerDismissed(id: String) -> Bool
    /// Record that the user dismissed this banner (persisted across launches) and
    /// remove it from the UI now. Wired to the banner's close button.
    func markBannerDismissed(id: String, in surface: HookBannerSurface)
    /// Forget a persisted dismissal so the banner can show again — e.g. when the
    /// owning project is deleted, so re-adding it surfaces the banner anew.
    func clearBannerDismissal(id: String)

    // MARK: Secrets

    /// Environments configured for a repo in autopilot. Returns `nil` when the
    /// check can't be completed (signed out, offline, request failed, or the
    /// task was cancelled mid-flight) so callers can tell that apart from a
    /// genuine empty `[]` and avoid surfacing a misleading banner.
    func secretEnvironments(repoFullName: String) async -> [HookChoice]?

    /// Whether a secret file named `filename` already exists in *any* of the
    /// repo's autopilot environments. Returns `true` on error / signed-out so
    /// callers don't nag the user when the check itself can't run.
    func secretFileExists(repoFullName: String, filename: String) async -> Bool
    /// Download + decrypt an environment's files (may prompt for the passkey).
    /// Does not write anything to disk.
    func fetchSecrets(repoFullName: String, env: String) async throws -> [HookSecretFile]
    /// Write decrypted files into a project folder, skipping existing files
    /// unless `overwrite`. Returns the filenames actually written.
    func writeSecrets(_ files: [HookSecretFile], toPath path: String, overwrite: Bool) throws -> [String]

    // MARK: CI auto-update

    /// Whether the repo is configured for CI auto-updates (a "watched
    /// repository"). Returns `nil` when the check can't be completed (signed out,
    /// offline, request failed) so callers can tell that apart from a genuine
    /// "not watched" and avoid surfacing a misleading banner.
    func ciRepoIsWatched(repoFullName: String) async -> Bool?

    // MARK: Docs

    /// Whether the repo has documentation indexed in the docs service. Returns
    /// `nil` when the check can't be completed (signed out, offline, request
    /// failed) so callers can tell that apart from a genuine "no docs" and avoid
    /// surfacing a misleading banner.
    func docsIndexed(repoFullName: String) async -> Bool?

    /// One-shot: if a docs-setup chat was kicked off for `projectId` (via the
    /// docs banner), returns the docs-publishing skill text to inject as the
    /// session's system prompt and clears the pending flag. Returns `nil`
    /// otherwise.
    func consumePendingDocsSetupSkill(projectId: UUID) -> String?
}

// MARK: - Banner surfaces

/// A screen region a hook can attach a banner to.
public enum HookBannerSurface: String, Sendable, Hashable {
    /// The new-project / empty-state composer screen.
    case newProject
}

/// Where within a surface the banner renders.
public enum HookBannerPosition: String, Sendable, Hashable {
    /// Directly above the chat input box (below the title on the empty state).
    case aboveInputBox
}

/// A live banner: its stable `id`, where it sits, and the hook-built view.
public struct HookBannerItem: Identifiable {
    public let id: String
    public let position: HookBannerPosition
    /// Project this banner belongs to; the host only renders it while that
    /// project is open. `nil` shows regardless of the selected project.
    public let projectId: UUID?
    public let content: AnyView

    public init(id: String, position: HookBannerPosition, projectId: UUID? = nil, content: AnyView) {
        self.id = id
        self.position = position
        self.projectId = projectId
        self.content = content
    }
}

public extension HookController {
    /// Ergonomic `@ViewBuilder` form mirroring the requested call site:
    /// `controller.showBanner(in: .newProject, position: .aboveInputBox, id: …) { MyBanner() }`.
    func showBanner<Content: View>(
        in surface: HookBannerSurface,
        position: HookBannerPosition,
        id: String,
        projectId: UUID? = nil,
        @ViewBuilder content: () -> Content
    ) {
        showBanner(AnyView(content()), id: id, projectId: projectId, in: surface, position: position)
    }
}
