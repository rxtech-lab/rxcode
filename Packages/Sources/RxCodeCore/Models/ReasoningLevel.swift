import Foundation

/// One selectable thinking/reasoning level for an agent.
///
/// The picker used to offer one hardcoded list to every provider, which was
/// only ever correct for Claude — Codex has no `xhigh` or `max`, and offering
/// them meant the menu showed levels the agent would reject. Each backend now
/// reports its own vocabulary instead.
///
/// `id` is the wire value, passed through to the agent verbatim: `--effort` for
/// Claude Code, `model_reasoning_effort` for Codex.
///
/// This mirrors `RxAgentCore.AgentReasoningOption`. It is a separate type for
/// the same reason the other shared models are — `RxCodeCore` is what the UI
/// imports, and it does not depend on the SDK. `AgentSDKConversions.swift`
/// translates between them.
public struct ReasoningLevel: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let displayName: String
    /// One line for a picker subtitle: when to reach for this level.
    public let levelDescription: String?

    public init(id: String, displayName: String, levelDescription: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.levelDescription = levelDescription
    }
}

public extension [ReasoningLevel] {

    /// What `claude --effort` accepts.
    static let claudeCodeEfforts: [ReasoningLevel] = [
        ReasoningLevel(
            id: "low",
            displayName: "Low",
            levelDescription: "Fastest and cheapest. Mechanical edits and small questions."
        ),
        ReasoningLevel(
            id: "medium",
            displayName: "Medium",
            levelDescription: "Everyday work where quality is holding up fine."
        ),
        ReasoningLevel(
            id: "high",
            displayName: "High",
            levelDescription: "Intelligence-sensitive work. A good quality/cost balance."
        ),
        ReasoningLevel(
            id: "xhigh",
            displayName: "Extra High",
            levelDescription: "Best for most coding and agentic tasks."
        ),
        ReasoningLevel(
            id: "max",
            displayName: "Max",
            levelDescription: "When correctness matters more than cost."
        ),
    ]

    /// What Codex's `model_reasoning_effort` accepts. Note the absence of
    /// `xhigh` and `max` — those are Claude's, and Codex rejects them.
    static let codexEfforts: [ReasoningLevel] = [
        ReasoningLevel(
            id: "minimal",
            displayName: "Minimal",
            levelDescription: "Barely reasons. Lowest latency."
        ),
        ReasoningLevel(
            id: "low",
            displayName: "Low",
            levelDescription: "Quick passes over small, well-specified changes."
        ),
        ReasoningLevel(
            id: "medium",
            displayName: "Medium",
            levelDescription: "The default. Balanced for everyday work."
        ),
        ReasoningLevel(
            id: "high",
            displayName: "High",
            levelDescription: "Hard problems worth the extra latency."
        ),
    ]

    /// Titlecases each wire value. For a provider that reports its levels as
    /// bare strings and whose names read well as-is.
    static func levels(_ ids: [String]) -> [ReasoningLevel] {
        ids.map { id in
            ReasoningLevel(
                id: id,
                displayName: id.replacingOccurrences(of: "_", with: " ").capitalized
            )
        }
    }
}
