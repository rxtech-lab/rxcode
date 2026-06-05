import Foundation
import SwiftData

/// Persisted copy of a synthetic hook *card* — a `ToolCall` a hook injects into
/// a session's message list (a code-review countdown, a commit request, a
/// send-message confirmation, an auto-continue notice, …). Hook cards are not
/// part of the agent's turn, so they never reach the CLI's jsonl transcript;
/// without this sidecar they vanish whenever a session's messages are reloaded
/// from disk.
///
/// Unlike the older single-row `HookStatusRecord` (one "last hook" per session),
/// this keeps **one row per card**, keyed by the card's tool-call `toolId`, so
/// *every* card a hook adds survives a reload — not just the most recent one.
///
/// The row is written at *insert* time (`isComplete == false`, a spinner) and
/// updated on completion, so a card also survives a reload that happens while a
/// long-running hook (e.g. code review) is still running. A row left in-progress
/// by a crashed/closed launch is swept to an "interrupted" state on next launch.
@Model
public final class HookCardRecord {
    /// The card's tool-call id. Unique, and what a rebuilt card dedupes against
    /// a still-live in-memory one so an active-stream reload won't duplicate it.
    @Attribute(.unique) public var toolId: String
    /// Session the card belongs to (one session has many cards).
    public var sessionId: String
    /// The tool-call `name` (e.g. `"Hook: Lint"`, `"Code Review Countdown"`,
    /// `"Auto-continue"`) — drives how `ToolResultView` renders the card.
    public var toolName: String
    /// JSON-encoded `[String: JSONValue]` card input, so the card rebuilds with
    /// the exact payload it was inserted with (summary text, parent key, …).
    public var inputData: Data
    /// The card's result text, or `nil` while it is still running (spinner).
    public var result: String?
    public var isError: Bool
    /// False while the card is still running.
    public var isComplete: Bool
    /// Insertion order, so cards rebuild in the order they were added.
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        toolId: String,
        sessionId: String,
        toolName: String,
        inputData: Data,
        result: String?,
        isError: Bool,
        isComplete: Bool,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.toolId = toolId
        self.sessionId = sessionId
        self.toolName = toolName
        self.inputData = inputData
        self.result = result
        self.isError = isError
        self.isComplete = isComplete
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
