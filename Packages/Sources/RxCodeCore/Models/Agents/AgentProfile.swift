import Foundation

/// A long-lived personal agent the user creates in the Agents tab.
///
/// Each agent owns two virtual projects so its threads reuse the normal chat
/// pipeline (streaming, persistence, search, mobile sync) without a repository:
/// - `id` holds the agent's own conversation threads, the ones the user chats
///   in on the Mac and in the phone's Chat tab;
/// - `subagentProjectId` holds the threads of subagents and scheduled runs the
///   agent dispatches, so they never mix with the conversation.
public struct AgentProfile: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    /// Owner of the threads of this agent's subagents and scheduled runs.
    public var subagentProjectId: UUID
    public var name: String
    /// SF Symbol shown as the agent's avatar.
    public var symbol: String
    /// `#RRGGBB` tint of the avatar.
    public var colorHex: String
    /// Id of the pet look the agent appears as, animated by what it is doing.
    /// `nil` shows `symbol` instead.
    public var petLookId: String?
    public var tone: AgentTone
    /// Free-form description of how the agent talks and behaves.
    public var personality: String
    /// Standing instructions: what the agent is for and how it should work.
    public var instructions: String
    /// Provider, model, effort and permission mode of every turn the agent runs.
    /// Subagents inherit it unless a spawn names another model.
    public var agent: TaskAgentConfig
    public var computerUse: AgentComputerUseSettings
    /// Whether the agent may push messages to paired phones.
    public var notifiesPhone: Bool
    /// Folder the agent works in. `nil` uses the agent's own home folder in the
    /// workspace's storage.
    public var workingDirectory: String?
    public struct PhoneMessage: Identifiable, Codable, Hashable, Sendable {
        public let id: UUID
        public let body: String
        public let sessionID: String?
        public let sentAt: Date

        public init(body: String, sessionID: String?) {
            id = UUID()
            self.body = body
            self.sessionID = sessionID
            sentAt = .now
        }
    }

    public var phoneMessages: [PhoneMessage] = []
    /// The conversation thread opened from the Agents tab and the phone. Set on
    /// the first message and followed across CLI session renames.
    public var primarySessionId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        subagentProjectId: UUID = UUID(),
        name: String,
        symbol: String = AgentProfile.defaultSymbol,
        colorHex: String = AgentProfile.palette[0],
        petLookId: String? = nil,
        tone: AgentTone = .friendly,
        personality: String = "",
        instructions: String = "",
        agent: TaskAgentConfig = TaskAgentConfig(),
        computerUse: AgentComputerUseSettings = AgentComputerUseSettings(),
        notifiesPhone: Bool = true,
        workingDirectory: String? = nil,
        primarySessionId: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.subagentProjectId = subagentProjectId
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.petLookId = petLookId
        self.tone = tone
        self.personality = personality
        self.instructions = instructions
        self.agent = agent
        self.computerUse = computerUse
        self.notifiesPhone = notifiesPhone
        self.workingDirectory = workingDirectory
        self.primarySessionId = primarySessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let defaultSymbol = "sparkles"
    public static let symbols = [
        "sparkles", "brain.head.profile", "person.crop.circle", "wand.and.stars", "bolt.fill",
        "leaf.fill", "moon.stars.fill", "flame.fill", "hammer.fill", "magnifyingglass",
        "chart.line.uptrend.xyaxis", "envelope.fill", "calendar", "desktopcomputer", "music.note",
    ]
    public static let palette = [
        "#D97757", "#3B82F6", "#10B981", "#8B5CF6", "#EC4899", "#F59E0B", "#14B8A6", "#6366F1",
    ]

    /// The name shown in lists; never empty.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Untitled Agent") : trimmed
    }

    /// A short line describing what the agent is for, from its instructions
    /// or personality. Empty when neither is set.
    public var roleSummary: String {
        let source = [instructions, personality]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let firstLine = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.count > 140 ? String(firstLine.prefix(139)) + "…" : firstLine
    }

    /// Whether `projectId` is one of this agent's two virtual projects.
    public func owns(projectId: UUID) -> Bool {
        projectId == id || projectId == subagentProjectId
    }

    private enum CodingKeys: String, CodingKey {
        case id, subagentProjectId, name, symbol, colorHex, petLookId, tone, personality, instructions, agent
        case computerUse, notifiesPhone, workingDirectory, primarySessionId, phoneMessages, createdAt, updatedAt
    }

    /// Tolerates missing keys so records written by older or newer builds load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        subagentProjectId = (try? c.decodeIfPresent(UUID.self, forKey: .subagentProjectId)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? Self.defaultSymbol
        colorHex = (try? c.decodeIfPresent(String.self, forKey: .colorHex)) ?? Self.palette[0]
        petLookId = try? c.decodeIfPresent(String.self, forKey: .petLookId)
        tone = (try? c.decodeIfPresent(AgentTone.self, forKey: .tone)) ?? .friendly
        personality = (try? c.decodeIfPresent(String.self, forKey: .personality)) ?? ""
        instructions = (try? c.decodeIfPresent(String.self, forKey: .instructions)) ?? ""
        agent = (try? c.decodeIfPresent(TaskAgentConfig.self, forKey: .agent)) ?? TaskAgentConfig()
        computerUse = (try? c.decodeIfPresent(AgentComputerUseSettings.self, forKey: .computerUse)) ?? AgentComputerUseSettings()
        notifiesPhone = (try? c.decodeIfPresent(Bool.self, forKey: .notifiesPhone)) ?? true
        workingDirectory = try? c.decodeIfPresent(String.self, forKey: .workingDirectory)
        phoneMessages = try c.decodeIfPresent([PhoneMessage].self, forKey: .phoneMessages) ?? []
        primarySessionId = try? c.decodeIfPresent(String.self, forKey: .primarySessionId)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? .now
        updatedAt = (try? c.decodeIfPresent(Date.self, forKey: .updatedAt)) ?? createdAt
    }
}

/// A preset voice for the agent, refined by `AgentProfile.personality`.
public enum AgentTone: String, Codable, Sendable, CaseIterable, Hashable {
    case friendly
    case concise
    case professional
    case playful
    case mentor

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentTone(rawValue: raw) ?? .friendly
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .friendly: "Friendly"
        case .concise: "Concise"
        case .professional: "Professional"
        case .playful: "Playful"
        case .mentor: "Mentor"
        }
    }

    public var displayNameText: String { String(localized: displayName) }

    /// How the tone is described to the model.
    public var promptDescription: String {
        switch self {
        case .friendly: "Warm and approachable. Speak naturally and keep replies easy to read."
        case .concise: "Brief and direct. Lead with the answer and skip filler."
        case .professional: "Clear, precise and neutral, like a capable chief of staff."
        case .playful: "Light-hearted and upbeat, without getting in the way of the work."
        case .mentor: "Patient and explanatory. Teach the reasoning behind suggestions."
        }
    }
}

// MARK: - Computer use

/// How an agent operates the Mac's screen, mouse and keyboard.
public struct AgentComputerUseSettings: Codable, Sendable, Hashable {
    public var isEnabled: Bool
    public var mode: AgentComputerUseMode
    /// LiteLLM-style model the open-source computer-use agent runs, such as
    /// `huggingface-local/ByteDance-Seed/UI-TARS-1.5-7B`.
    public var openSourceModel: String

    public init(
        isEnabled: Bool = false,
        mode: AgentComputerUseMode = .automatic,
        openSourceModel: String = AgentComputerUseSettings.defaultOpenSourceModel
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.openSourceModel = openSourceModel
    }

    public static let defaultOpenSourceModel = "huggingface-local/ByteDance-Seed/UI-TARS-1.5-7B"

    /// Models offered as shortcuts for the open-source agent. Any LiteLLM model
    /// string the cua agent accepts can be typed instead.
    public static let openSourceModelPresets: [(title: String, model: String)] = [
        ("UI-TARS 1.5 7B (local)", "huggingface-local/ByteDance-Seed/UI-TARS-1.5-7B"),
        ("OmniParser + Ollama Llama 3.2 Vision", "omniparser+ollama_chat/llama3.2-vision"),
        ("OpenCUA 7B (local)", "huggingface-local/xlangai/OpenCUA-7B"),
    ]

    private enum CodingKeys: String, CodingKey { case isEnabled, mode, openSourceModel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? false
        mode = (try? c.decodeIfPresent(AgentComputerUseMode.self, forKey: .mode)) ?? .automatic
        let model = (try? c.decodeIfPresent(String.self, forKey: .openSourceModel)) ?? ""
        openSourceModel = model.isEmpty ? Self.defaultOpenSourceModel : model
    }

    /// The driver a turn with `provider`/`model` uses, or `nil` when computer
    /// use is off.
    public func resolvedDriver(provider: AgentProvider?, model: String?) -> AgentComputerUseDriver? {
        guard isEnabled else { return nil }
        switch mode {
        case .native: return .native
        case .openSource: return .openSource
        case .automatic:
            return ComputerUseSupport.modelSupportsComputerUse(provider: provider, model: model) ? .native : .openSource
        }
    }
}

/// The user's choice of computer-use driver.
public enum AgentComputerUseMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// Native tools when the model supports computer use, else the open-source agent.
    case automatic
    /// RxCode's screenshot, mouse and keyboard tools, driven by the agent's model.
    case native
    /// The open-source cua agent, which runs its own grounding model.
    case openSource

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentComputerUseMode(rawValue: raw) ?? .automatic
    }

    public var displayName: LocalizedStringResource {
        switch self {
        case .automatic: "Automatic"
        case .native: "Model's Own Computer Use"
        case .openSource: "Open-Source Agent (cua)"
        }
    }
}

/// The driver a computer-use turn actually runs with.
public enum AgentComputerUseDriver: String, Codable, Sendable, Hashable {
    case native
    case openSource
}

/// Which models can drive the screen from screenshots themselves. Models that
/// can't delegate GUI work to the open-source agent instead.
public enum ComputerUseSupport {
    /// Model-name fragments of vision models trained for computer use.
    static let capableModelFragments = [
        "claude", "opus", "sonnet", "haiku", "fable",
        "gpt-5", "gpt-4.1", "gpt-4o", "o3", "o4", "computer-use", "operator", "codex",
        "gemini", "ui-tars", "opencua", "qwen2.5-vl", "qwen3-vl", "glm-4.5v", "glm-4.6v",
    ]

    public static func modelSupportsComputerUse(provider: AgentProvider?, model: String?) -> Bool {
        let name = (model ?? "").lowercased()
        switch provider {
        case .claudeCode, .codex, nil:
            // Every model these CLIs serve is a multimodal computer-use model.
            return true
        case .acp, .localAgent:
            guard !name.isEmpty else { return false }
            return capableModelFragments.contains { name.contains($0) }
        case .flowcy:
            return false
        }
    }
}
