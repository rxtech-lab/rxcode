import Foundation
import RxCodeCore

extension AppState {
    static func fallbackShouldInjectMemoryIntoSystemPrompt(_ item: MemoryItem) -> Bool {
        if item.kind.lowercased() == "preference" { return true }
        let text = normalizedMemoryIntentText(item.content)
        return containsAny(text, phrases: systemPromptMemoryPhrases)
    }

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
