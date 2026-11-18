import Foundation

/// One selectable thinking/reasoning level for an agent.
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
