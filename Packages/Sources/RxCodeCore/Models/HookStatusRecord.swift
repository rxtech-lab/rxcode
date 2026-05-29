import Foundation
import SwiftData

/// Persisted status of the most recent hook card for a session. One row per
/// `sessionId` — we only keep the last hook (start/stop) so its card survives a
/// reload, mirroring how `PlanDecisionRecord` keeps plan decisions alive across
/// CLI-backed session reloads. Hook cards are synthetic `ChatMessage`s injected
/// by `runHooks`; they never reach the CLI's jsonl transcript, so without this
/// sidecar they vanish when messages are reloaded from disk.
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
    public var updatedAt: Date

    public init(
        sessionId: String,
        toolId: String,
        name: String,
        trigger: String,
        output: String,
        isError: Bool,
        updatedAt: Date = .now
    ) {
        self.sessionId = sessionId
        self.toolId = toolId
        self.name = name
        self.trigger = trigger
        self.output = output
        self.isError = isError
        self.updatedAt = updatedAt
    }
}
