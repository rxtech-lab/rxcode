import Foundation
import RxCodeCore

extension AppState {
    static func hasExplicitMemoryIntent(_ message: String) -> Bool {
        let text = normalizedMemoryIntentText(message)
        guard !text.isEmpty else { return false }

        return containsAny(text, phrases: explicitMemoryPhrases)
            || containsAny(text, phrases: preferencePhrases)
            || containsAny(text, phrases: futureInstructionPhrases)
    }

    static func shouldAcceptAgentMemoryAdd(content: String, kind: String?) -> Bool {
        let text = normalizedMemoryIntentText(content)
        guard !text.isEmpty else { return false }
        if hasExplicitMemoryIntent(content) { return true }
        if containsAny(text, phrases: transientMemoryPhrases) { return false }

        switch kind?.lowercased() {
        case "preference":
            return true
        default:
            return false
        }
    }

    static func shouldInjectMemoryIntoSystemPrompt(_ item: MemoryItem) -> Bool {
        if item.kind.lowercased() == "preference" { return true }
        let text = normalizedMemoryIntentText(item.content)
        return containsAny(text, phrases: systemPromptMemoryPhrases)
    }

    private static let explicitMemoryPhrases = [
        "please remember",
        "remember that",
        "remember to",
        "remember this",
        "remember my",
        "save this",
        "save that",
        "store this",
        "store that",
        "add this to memory",
        "add that to memory",
        "add to memory",
        "keep this in memory",
        "keep that in memory",
        "memorize this",
        "forget that",
        "forget this",
        "delete that memory",
        "delete this memory",
        "remove that memory",
        "remove this memory",
        "that memory is wrong",
        "this memory is wrong",
        "memory is wrong",
        "no longer remember"
    ]

    private static let preferencePhrases = [
        "i prefer",
        "my preference is",
        "my preferred",
        "i like to",
        "i don't like",
        "i do not like",
        "i want agents to",
        "i want codex to",
        "i want the agent to",
        "i want you to always",
        "i want you to never",
        "the user prefers",
        "user prefers"
    ]

    private static let futureInstructionPhrases = [
        "from now on",
        "going forward",
        "in the future",
        "next time",
        "next time you",
        "for future",
        "in future",
        "always use",
        "always do",
        "always ask",
        "always run",
        "never use",
        "never do",
        "never ask",
        "never run",
        "by default",
        "default to"
    ]

    private static let systemPromptMemoryPhrases = [
        "always",
        "never",
        "from now on",
        "going forward",
        "in the future",
        "next time",
        "for future",
        "in future",
        "by default",
        "default to"
    ]

    private static let transientMemoryPhrases = [
        "0 errors",
        "0 warnings",
        "added ",
        "build successfully",
        "builds successfully",
        "deleted ",
        "fixed ",
        "i have access",
        "implemented ",
        "make lint",
        "removed ",
        "script removed",
        "untracked",
        "works"
    ]

    private static func normalizedMemoryIntentText(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func containsAny(_ text: String, phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }
}
