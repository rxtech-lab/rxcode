import Foundation
import RxCodeCore

extension AppState {
    /// Drop "No response requested." text blocks from the assistant message
    /// at `idx`. The marker is the model's response when a turn arrives
    /// without a user prompt (ScheduleWakeup, hook re-entry) and reads as
    /// noise in the chat UI.
    ///
    /// `removeIfEmpty` controls whether a message left with no blocks is also
    /// deleted. The normal stream path passes `true` to discard pure no-op
    /// envelopes; the cancel path passes `false` so pausing a turn never makes
    /// the partial assistant bubble disappear.
    static func stripNoOpText(at idx: Int, in messages: inout [ChatMessage], removeIfEmpty: Bool = true) {
        guard messages.indices.contains(idx) else { return }
        messages[idx].blocks.removeAll { block in
            guard let text = block.text else { return false }
            return CLIMetaEnvelope.isNoResponseRequested(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if removeIfEmpty, messages[idx].blocks.isEmpty {
            messages.remove(at: idx)
        }
    }

    /// Wrap a branch briefing into a system-prompt section the agent can use as
    /// background context. The briefing is auto-generated from earlier threads,
    /// so it is framed as advisory rather than authoritative.
    static func branchBriefingSystemPrompt(branch: String, briefing: String) -> String {
        let trimmed = briefing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return """
        # Current branch briefing

        The notes below are an accumulated briefing of recent work on this \
        project's current branch (`\(branch)`). They are auto-generated from \
        previous chat threads — treat them as background context for the user's \
        request, and be aware they may be incomplete or slightly out of date.

        \(trimmed)
        """
    }

    static func promptWithBackgroundContext(_ contexts: [String], prompt: String) -> String {
        let context = contexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !context.isEmpty else { return prompt }
        return """
        \(context)

        User request:
        \(prompt)
        """
    }

    nonisolated static func streamEventLogName(_ event: StreamEvent) -> String {
        switch event {
        case .system(let systemEvent):
            return "system.\(systemEvent.subtype)"
        case .assistant:
            return "assistant"
        case .user:
            return "user"
        case .result:
            return "result"
        case .rateLimitEvent:
            return "rateLimitEvent"
        case .todoSnapshot:
            return "todoSnapshot"
        case .acpModelsDiscovered:
            return "acpModelsDiscovered"
        case .unknown:
            return "unknown"
        }
    }
}
