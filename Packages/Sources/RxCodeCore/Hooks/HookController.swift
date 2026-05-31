import Foundation

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
}
