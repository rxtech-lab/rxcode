import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable, Hashable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

public struct AgentModel: Identifiable, Codable, Sendable, Hashable {
    public let provider: AgentProvider
    public let id: String
    public let displayName: String
    public let description: String

    public var key: String { "\(provider.rawValue):\(id)" }

    public init(provider: AgentProvider, id: String, displayName: String, description: String = "") {
        self.provider = provider
        self.id = id
        self.displayName = displayName
        self.description = description
    }
}
