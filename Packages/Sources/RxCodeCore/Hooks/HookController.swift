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
    /// reload (hook cards never reach the CLI transcript). Pass `isComplete:
    /// false` at insert time for a long-running hook so an in-progress card
    /// survives a reload; call again with `isComplete: true` on completion.
    func persistHookStatus(sessionKey: String, toolId: String, name: String, trigger: String, output: String, isError: Bool, isComplete: Bool)

    /// Enabled user hook profiles for a project + trigger, loading from disk on
    /// first access.
    func enabledHookProfiles(projectId: UUID, trigger: HookTrigger) async -> [HookProfile]

    // MARK: Queries

    var notificationsEnabled: Bool { get }
    var isAppActive: Bool { get }

    func project(for id: UUID) -> Project?
    /// The display title of a session (from its summary), if known.
    func sessionTitle(sessionId: String) -> String?

    // MARK: Thread linkage / cross-thread sends (code-review & commit hooks)

    /// Whether the thread should skip all lifecycle hooks (e.g. a review thread).
    func threadSkipsHooks(sessionId: String) -> Bool
    /// Whether session-end lifecycle hooks must be skipped for the current turn
    /// because it is a *planning* turn — the session is in plan mode, or the
    /// agent emitted an `ExitPlanMode` plan the user hasn't decided yet. Code
    /// review, commit/push, and every other stop hook must not run on a plan
    /// (reviewing/committing an unaccepted plan is always wrong). Enforced
    /// centrally in `HookManager` ahead of both the completion and cancellation
    /// session-end dispatch paths.
    func sessionEndHooksSuppressed(sessionKey: String, sessionId: String) -> Bool
    /// Resolve a stored hook model selection into the provider/model pair used
    /// for a spawned agent thread. Empty selections inherit the reviewed thread.
    func resolveAgentModelSelection(storedModel: String?, fallbackSessionId: String) -> (provider: AgentProvider, model: String)?
    /// Distinct paths of files edited during the thread.
    func changedFilePaths(sessionId: String) -> [String]
    /// The first user prompt text of a thread, if any.
    func firstUserPrompt(sessionId: String) -> String?
    /// A readable transcript of a thread's assistant *text*, used to fold a review
    /// thread's content into a card on the parent thread. Tool calls and the
    /// injected instruction prompt are excluded so the result shown back on the
    /// parent thread is prose, not a list of tool names.
    func threadTranscript(sessionId: String) -> String
    /// Spawn a new linked thread (e.g. `[Code Review]`) that runs no hooks, and
    /// wait for its first response. Returns the resolved thread id + assistant
    /// text, or `nil` if it could not be sent.
    func spawnLinkedThread(
        projectId: UUID,
        parentThreadId: String,
        label: String,
        agentProvider: AgentProvider?,
        model: String?,
        prompt: String,
        timeoutSeconds: TimeInterval
    ) async -> HookLinkedThreadResult?
    /// Send a follow-up prompt into an existing thread without waiting. Pass
    /// `setupKind` to mark the session for once-per-session loop prevention; the
    /// marker is recorded *after* the message is appended, so the resulting turn
    /// doesn't clear its own marker.
    func sendThreadMessage(sessionId: String, prompt: String, setupKind: String?)
    /// Ask a lightweight model whether `condition` holds given the turn's final
    /// assistant text. Returns `true` only on an explicit YES, `false` on NO, and
    /// `nil` when no verdict could be obtained. `model` is a provider-qualified
    /// override (empty/`nil` ⇒ the configured summarization model).
    func evaluateCondition(condition: String, lastAssistantText: String, model: String?, sessionId: String) async -> Bool?
    // MARK: Review debounce / cancellation

    /// Debounce applied before an automatic code review starts, in seconds. The
    /// hook shows a countdown card for this long so a new follow-up message can
    /// cancel the review before it runs.
    var reviewCountdownSeconds: TimeInterval { get }
    /// Suspend until the review countdown for `parentSessionKey` elapses, the
    /// user taps "Start it now", or it is cancelled (Stop button / new message).
    /// Returns `true` to proceed with the review, `false` if it was cancelled.
    func awaitReviewGate(parentSessionKey: String, delaySeconds: TimeInterval) async -> Bool
    /// Mark/clear that the review thread for `parentSessionKey` is running, so a
    /// later cancellation can stop the in-flight review thread and the context
    /// menu can show "Stop Code Review".
    func markReviewRunning(parentSessionKey: String)
    func clearReviewRunning(parentSessionKey: String)
    /// One-shot: whether the running review for `parentSessionKey` was stopped
    /// (by a new message or the Stop action) rather than finishing on its own.
    func reviewWasStopped(parentSessionKey: String) -> Bool
    /// Why the most recent cancel happened for the thread, so the hook can word
    /// the finalized card correctly (e.g. an explicit Stop vs a new message).
    func reviewCancelReason(parentSessionKey: String) -> ReviewCancelReason?
    /// Whether a review is pending (counting down) or running for the thread —
    /// gates the "Stop Code Review" context-menu item. Synchronous because the
    /// menu is built synchronously.
    func threadHasOngoingReview(sessionId: String) -> Bool
    /// Whether the thread already has a newer turn in progress (streaming or a
    /// freshly-appended, not-yet-answered user message). Lets the review hook
    /// skip reviewing a turn the user has already superseded with a follow-up.
    func threadHasNewerActivity(sessionId: String) -> Bool

    /// Record the latest review verdict for a session (shared between the
    /// code-review and commit hooks within one stop cycle).
    func setReviewPassed(_ passed: Bool, sessionId: String)
    /// The latest recorded review verdict for a session, or `nil` if none.
    func reviewPassed(sessionId: String) -> Bool?
    /// Number of failed-review re-prompt rounds so far for a session (bounds the
    /// review→fix→review loop).
    func reviewRound(sessionId: String) -> Int
    /// Set the failed-review round counter for a session.
    func setReviewRound(_ round: Int, sessionId: String)
    /// The previous failing review's feedback for a session, carried into the
    /// next review so it can focus on whether those issues were fixed instead of
    /// reviewing from scratch. `nil` when the next review should start fresh.
    func lastReviewFeedback(sessionId: String) -> String?
    /// Store (or clear, with `nil`) the failing review feedback to carry into the
    /// session's next review turn.
    func setLastReviewFeedback(_ feedback: String?, sessionId: String)
    /// Feed a failing code review's feedback back into the reviewed thread as a
    /// bounded auto-continue fix turn (rendered as an auto-continue card, not a
    /// user message). The thread runs the Code Review hook again when the fix
    /// turn finishes, so the change is re-reviewed. Returns the 1-based attempt
    /// number started, or `nil` if the per-session fix-round cap was already
    /// reached (the caller then surfaces a "stopped" card instead of looping).
    func repromptThreadAfterReviewFailure(feedback: String, project: Project, sessionKey: String) -> Int?
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

    // MARK: Release

    /// Whether the repo has a release workflow set up (registered with the
    /// release service AND has a selected dispatchable workflow). Returns `nil`
    /// when the check can't be completed (signed out, offline, request failed)
    /// so callers can tell that apart from a genuine "not set up" and avoid
    /// surfacing a misleading banner.
    func releaseConfigured(repoFullName: String) async -> Bool?

    /// One-shot: if a release-setup chat was kicked off for `projectId` (via the
    /// release banner), returns the release skill text to inject as the session's
    /// system prompt and clears the pending flag. Returns `nil` otherwise.
    func consumePendingReleaseSetupSkill(projectId: UUID) -> String?

    // MARK: Context menu actions

    /// Cached context-menu status for a project's linked repository. These are
    /// intentionally synchronous because SwiftUI builds context menus
    /// synchronously when the user opens them.
    func projectHasSecrets(_ project: Project) -> Bool
    func projectHasDocs(_ project: Project) -> Bool
    func projectHasReleaseWorkflow(_ project: Project) -> Bool
    /// Whether the project's linked repo is already configured for CI
    /// auto-updates (a "watched repository"). Hides "Set Up CI Update" when it's
    /// already set up; also false when the project has no GitHub repo or the
    /// status cache hasn't been populated yet (fail-open: the item shows).
    func projectHasCIUpdates(_ project: Project) -> Bool

    /// Whether the project's working tree has uncommitted changes (gates the
    /// "Commit All Changes" item). Defaults to visible when status is unknown.
    func projectHasUncommittedChanges(_ project: Project) -> Bool
    /// Whether the project already has an open pull request for `branch` (or the
    /// project's current branch when `branch` is nil). Hides "Create Pull Request"
    /// when one exists; also false when the project has no GitHub repo.
    func projectHasOpenPullRequest(_ project: Project, branch: String?) -> Bool
    /// Whether CI is currently failing for `branch` (or the project's current
    /// branch when `branch` is nil). Gates the "Fix Failing CI" item; false when
    /// the project has no GitHub repo or no CI status is known yet.
    func projectCIIsFailing(_ project: Project, branch: String?) -> Bool
    /// Whether the thread recorded any file edits (gates "Commit Files").
    func threadHasFileChanges(sessionId: String) -> Bool

    /// Enabled user-defined custom menu items for `surface`, scoped to `projectId`
    /// (plus the "all projects" items). Backs the `CustomMenuHook`.
    func customMenuItems(projectId: UUID?, surface: CustomMenuItemRecord.Surface) -> [CustomMenuItemRecord]

    /// Whether a custom menu item passes its show condition in this context.
    /// `always` items always pass; a `swiftScript` item is gated on its compiled
    /// script (evaluated asynchronously and cached — a cache miss shows the item,
    /// failing open). Synchronous so it fits the context-menu build path.
    func shouldShowConditionalMenuItem(
        _ record: CustomMenuItemRecord,
        project: Project,
        branch: String?,
        sessionId: String?
    ) -> Bool

    /// Centralized presentation actions used by hook-supplied context menus.
    func requestSecretsSetup(project: Project)
    func requestSecretsDownload(project: Project)
    func requestDocsSetup(project: Project)
    func requestDocsSearch(project: Project)
    func requestReleaseSetup(project: Project)
    func requestReleaseCreate(project: Project)
    func requestCISetup(project: Project)

    // MARK: Setup-session tracking

    /// Record that `sessionKey` belongs to a setup chat of the given `kind` (e.g.
    /// "release", "docs"). A setup hook marks the session on start and re-checks
    /// the backing status on each completed turn until setup is confirmed — so the
    /// marker is *peeked* (`isSetupSession`), not consumed, until `clearSetupSession`.
    /// Multi-turn setups (the agent asks a question first) therefore aren't lost
    /// after the first turn completes.
    func markSetupSession(kind: String, sessionKey: String)

    /// Whether `sessionKey` was recorded as a setup chat of `kind`. Non-destructive.
    func isSetupSession(kind: String, sessionKey: String) -> Bool

    /// Stop tracking `sessionKey` for `kind` — called once setup is confirmed
    /// complete so later turns don't re-check.
    func clearSetupSession(kind: String, sessionKey: String)
}

/// Stable `kind` identifiers for `markSetupSession` / `isSetupSession` /
/// `clearSetupSession`, so hooks don't collide on free-form strings.
public enum HookSetupKind {
    public static let release = "release"
    public static let docs = "docs"
    /// Marks the follow-up turn the Commit & Push hook itself triggered, so the
    /// hook short-circuits on that turn instead of looping forever.
    public static let commitPush = "commitPush"
    /// Marks a thread that the Send Message hook has already fired for this
    /// session. Unlike `commitPush` it is *not* self-cleared; it persists until
    /// the user sends a new message (reset in `AppState.sendPrompt`), giving the
    /// hook once-per-session semantics.
    public static let sendMessage = "sendMessage"
}

/// Result of spawning a linked thread via `spawnLinkedThread`.
public struct HookLinkedThreadResult: Sendable {
    /// The resolved (non-`pending-`) thread id of the spawned thread.
    public let threadId: String
    /// The reviewer/agent's first response text (empty on timeout).
    public let assistantText: String
    /// A transport/agent error, if any.
    public let error: String?

    public init(threadId: String, assistantText: String, error: String?) {
        self.threadId = threadId
        self.assistantText = assistantText
        self.error = error
    }
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
    /// Convenience: send a follow-up prompt without marking a setup session.
    func sendThreadMessage(sessionId: String, prompt: String) {
        sendThreadMessage(sessionId: sessionId, prompt: prompt, setupKind: nil)
    }

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
