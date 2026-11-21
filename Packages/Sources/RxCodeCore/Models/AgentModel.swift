import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable, Hashable {
    case claudeCode
    case codex
    case acp
    /// RxCode's own in-process agent (RxAgentHarness) running a local model
    /// downloaded from Hugging Face.
    case localAgent
    case flowcy

    public var displayName: LocalizedStringResource {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .acp: return "ACP"
        case .localAgent: return "RxCode Agent"
        case .flowcy: return "Flowcy"
        }
    }

    public var displayNameText: String {
        String(localized: displayName)
    }

    /// Tolerant decoding: a provider added by a newer build (desktop and mobile
    /// versions can differ) decodes as Claude Code instead of failing the whole
    /// payload — a thread list or settings snapshot is worth more than one
    /// mislabelled row.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentProvider(rawValue: raw) ?? .claudeCode
    }

    /// Default `SessionOrigin` for sessions originated by this provider.
    /// Used when creating placeholder summaries and computing the persistence
    /// route for newly-saved sessions.
    public var defaultSessionOrigin: SessionOrigin {
        switch self {
        case .claudeCode: return .cliBacked
        case .codex: return .codexAppServer
        // These providers use RxCode’s JSON transcript for replay.
        case .acp, .localAgent, .flowcy: return .acpAgent
        }
    }
}

public struct AgentModel: Identifiable, Codable, Sendable, Hashable {
    /// Picker value that lets the Flowcy server choose the model for a chat.
    public static let flowcyDefaultID = "flowcy-default"
    public let provider: AgentProvider
    public let id: String
    public let displayName: String
    public let description: String

    public var key: String { Self.key(for: id, provider: provider) }

    public static func key(for id: String, provider: AgentProvider) -> String {
        "\(provider.rawValue):\(id)"
    }

    public init(provider: AgentProvider, id: String, displayName: String, description: String = "") {
        self.provider = provider
        self.id = id
        self.displayName = displayName
        self.description = description
    }
}

/// A named group of agent models as presented in the model picker. Mirrors the
/// desktop's section layout — Claude Code, Codex, and one section per enabled
/// ACP client — so other surfaces (e.g. the mobile app) can reproduce the same
/// grouping instead of collapsing every ACP client into a single bucket.
public struct AgentModelSection: Identifiable, Codable, Sendable, Hashable {
    /// Stable section identifier (`claudeCode`, `codex`, or `acp:<clientId>`).
    public let id: String
    /// Human-readable section header (e.g. "Claude Code" or an ACP client name).
    public let title: String
    public let provider: AgentProvider
    /// Remote icon URL for ACP client sections; `nil` for built-in providers.
    public let iconURL: String?
    public let models: [AgentModel]

    public init(
        id: String,
        title: String,
        provider: AgentProvider,
        iconURL: String? = nil,
        models: [AgentModel]
    ) {
        self.id = id
        self.title = title
        self.provider = provider
        self.iconURL = iconURL
        self.models = models
    }
}
