import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable, Hashable {
    case claudeCode
    case codex
    case acp

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .acp: return "ACP"
        }
    }

    /// Default `SessionOrigin` for sessions originated by this provider.
    /// Used when creating placeholder summaries and computing the persistence
    /// route for newly-saved sessions.
    public var defaultSessionOrigin: SessionOrigin {
        switch self {
        case .claudeCode: return .cliBacked
        case .codex: return .codexAppServer
        case .acp: return .acpAgent
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
