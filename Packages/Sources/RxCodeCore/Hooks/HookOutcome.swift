import Foundation

/// The result of a single hook handling one event.
///
/// `contextOutput` is text the hook contributes back to the agent's context
/// (a start hook's stdout); `isError` mirrors a non-zero bash exit so a failing
/// stop hook can auto-continue the agent; `block` lets a hook veto the action
/// (reserved for future use — e.g. denying a permission or plan from a plugin).
public struct HookOutcome: Sendable {
    public enum Control: Sendable {
        /// The hook did not handle this event (the default no-op).
        case ignored
        /// The hook handled the event; proceed normally.
        case proceed
        /// The hook wants to veto/stop the action. `blockReason` explains why.
        case block
    }

    public let control: Control
    public let contextOutput: String?
    public let isError: Bool
    public let blockReason: String?

    public init(control: Control, contextOutput: String? = nil, isError: Bool = false, blockReason: String? = nil) {
        self.control = control
        self.contextOutput = contextOutput
        self.isError = isError
        self.blockReason = blockReason
    }

    public static let ignored = HookOutcome(control: .ignored)
    public static let proceed = HookOutcome(control: .proceed)

    /// A handled outcome that contributes `text` to the agent context. Pass
    /// `isError: true` to signal a non-zero exit (used by stop-hook auto-continue).
    public static func output(_ text: String, isError: Bool = false) -> HookOutcome {
        HookOutcome(control: .proceed, contextOutput: text.isEmpty ? nil : text, isError: isError)
    }

    public static func block(_ reason: String) -> HookOutcome {
        HookOutcome(control: .block, blockReason: reason)
    }
}

/// The folded result of dispatching one event to every registered hook. A
/// drop-in replacement for the old `HookBatchResult`: `combinedOutput` feeds
/// start-hook context injection or a failing stop hook's reprompt; `hasError`
/// is true if any hook signaled a non-zero exit.
public struct HookAggregateResult: Sendable {
    public let combinedOutput: String
    public let hasError: Bool
    public let blocked: Bool
    public let blockReason: String?

    public init(combinedOutput: String, hasError: Bool, blocked: Bool = false, blockReason: String? = nil) {
        self.combinedOutput = combinedOutput
        self.hasError = hasError
        self.blocked = blocked
        self.blockReason = blockReason
    }

    public static let empty = HookAggregateResult(combinedOutput: "", hasError: false)

    /// Fold a sequence of outcomes (run in registration order) into one result.
    public static func fold(_ outcomes: [HookOutcome]) -> HookAggregateResult {
        let outputs = outcomes.compactMap(\.contextOutput).filter { !$0.isEmpty }
        let hasError = outcomes.contains(where: \.isError)
        let firstBlock = outcomes.first { $0.control == .block }
        return HookAggregateResult(
            combinedOutput: outputs.joined(separator: "\n\n"),
            hasError: hasError,
            blocked: firstBlock != nil,
            blockReason: firstBlock?.blockReason
        )
    }
}

/// Handle to a synthetic chat "card" inserted by a hook, so the hook can fill in
/// the card's result once its work finishes.
public struct HookCardHandle: Sendable {
    public let toolId: String
    public let messageId: UUID

    public init(toolId: String, messageId: UUID) {
        self.toolId = toolId
        self.messageId = messageId
    }
}
