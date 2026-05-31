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

    // MARK: Secrets

    /// Environments configured for a repo in autopilot. Returns `[]` when there
    /// are none, the user is signed out, or the request fails.
    func secretEnvironments(repoFullName: String) async -> [HookChoice]
    /// Download + decrypt an environment's files (may prompt for the passkey).
    /// Does not write anything to disk.
    func fetchSecrets(repoFullName: String, env: String) async throws -> [HookSecretFile]
    /// Write decrypted files into a project folder, skipping existing files
    /// unless `overwrite`. Returns the filenames actually written.
    func writeSecrets(_ files: [HookSecretFile], toPath path: String, overwrite: Bool) throws -> [String]
}
