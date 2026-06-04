import Foundation
import SwiftData

/// Persisted status of the most recent hook card for a session. One row per
/// `sessionId` — we only keep the last hook (start/stop) so its card survives a
/// reload, mirroring how `PlanDecisionRecord` keeps plan decisions alive across
/// CLI-backed session reloads. Hook cards are synthetic `ChatMessage`s injected
/// by `runHooks`; they never reach the CLI's jsonl transcript, so without this
/// sidecar they vanish when messages are reloaded from disk.
///
/// The row is written at *insert* time (in-progress) for long-running hooks
/// like code review, so the card survives a reload that happens mid-run, and
/// updated again on completion.
@Model
public final class HookStatusRecord {
    @Attribute(.unique) public var sessionId: String
    /// The original tool-call id of the hook card, so the rebuilt card dedupes
    /// against a live in-memory one.
    public var toolId: String
    public var name: String
    /// `HookTrigger.displayName` at the time the hook ran.
    public var trigger: String
    public var output: String
    public var isError: Bool
    /// False while the hook card is still running (spinner). Defaulted `true`
    /// so existing rows migrate as already-finished. An in-progress row is
    /// rebuilt as a running card and finalized on completion — or, if the app
    /// closed mid-hook, swept to an "interrupted" state on next launch.
    public var isComplete: Bool = true
    public var updatedAt: Date

    public init(
        sessionId: String,
        toolId: String,
        name: String,
        trigger: String,
        output: String,
        isError: Bool,
        isComplete: Bool = true,
        updatedAt: Date = .now
    ) {
        self.sessionId = sessionId
        self.toolId = toolId
        self.name = name
        self.trigger = trigger
        self.output = output
        self.isError = isError
        self.isComplete = isComplete
        self.updatedAt = updatedAt
    }
}
