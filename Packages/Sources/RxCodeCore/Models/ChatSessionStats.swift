import Foundation

/// Per-session statistics displayed in the chat status area.
public struct ChatSessionStats: Sendable {
    public var costUsd: Double = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var durationMs: Double = 0
    public var turns: Int = 0

    public init() {}

    public init(
        costUsd: Double,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        durationMs: Double,
        turns: Int
    ) {
        self.costUsd = costUsd
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.durationMs = durationMs
        self.turns = turns
    }
}
