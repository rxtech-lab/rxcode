import Foundation

// MARK: - Stream Event (Top-Level)

public enum StreamEvent: Sendable {
    case system(SystemEvent)
    case assistant(AssistantMessage)
    case user(UserMessage)
    case result(ResultEvent)
    case rateLimitEvent(RateLimitInfo)
    case todoSnapshot(TodoSnapshotEvent)
    case unknown(String)
}

// MARK: - System Event

public struct SystemEvent: Sendable {
    public let subtype: String
    public let sessionId: String?
    public let tools: [String]?
    public let model: String?
    public let claudeCodeVersion: String?

    public init(subtype: String, sessionId: String?, tools: [String]?, model: String?, claudeCodeVersion: String?) {
        self.subtype = subtype
        self.sessionId = sessionId
        self.tools = tools
        self.model = model
        self.claudeCodeVersion = claudeCodeVersion
    }
}

// MARK: - Assistant Message

public struct AssistantMessage: Sendable {
    public let id: String?
    public let role: String
    public let content: [ContentBlock]
    public let usage: UsageInfo?

    public init(id: String? = nil, role: String, content: [ContentBlock], usage: UsageInfo? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.usage = usage
    }
}

// MARK: - Content Block

public enum ContentBlock: Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case thinking(String)
}

// MARK: - User Message (Tool Result)

public struct UserMessage: Sendable {
    public let toolUseId: String?
    public let content: String
    public let isError: Bool

    public init(toolUseId: String?, content: String, isError: Bool) {
        self.toolUseId = toolUseId
        self.content = content
        self.isError = isError
    }
}

// MARK: - Todo Snapshot Event

public struct TodoSnapshotEvent: Sendable {
    public let sessionId: String?
    public let items: [TodoItem]

    public init(sessionId: String?, items: [TodoItem]) {
        self.sessionId = sessionId
        self.items = items
    }
}

// MARK: - Usage Info

public struct UsageInfo: Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationInputTokens: Int
    public let cacheReadInputTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheCreationInputTokens: Int, cacheReadInputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

// MARK: - Context Window Info

public struct ContextWindowInfo: Sendable {
    public let usedPercentage: Double
    public let remainingPercentage: Double

    public init(usedPercentage: Double, remainingPercentage: Double) {
        self.usedPercentage = usedPercentage
        self.remainingPercentage = remainingPercentage
    }
}

// MARK: - Result Event

public struct ResultEvent: Sendable {
    public let durationMs: Double?
    public let totalCostUsd: Double?
    public let sessionId: String
    public let isError: Bool
    public let totalTurns: Int?
    public let usage: UsageInfo?
    public let contextWindow: ContextWindowInfo?

    public init(durationMs: Double?, totalCostUsd: Double?, sessionId: String, isError: Bool,
                totalTurns: Int?, usage: UsageInfo?, contextWindow: ContextWindowInfo?) {
        self.durationMs = durationMs
        self.totalCostUsd = totalCostUsd
        self.sessionId = sessionId
        self.isError = isError
        self.totalTurns = totalTurns
        self.usage = usage
        self.contextWindow = contextWindow
    }
}

// MARK: - Rate Limit Info

public struct RateLimitInfo: Sendable {
    public let status: String
    public let retrySec: Double?

    public init(status: String, retrySec: Double?) {
        self.status = status
        self.retrySec = retrySec
    }
}
