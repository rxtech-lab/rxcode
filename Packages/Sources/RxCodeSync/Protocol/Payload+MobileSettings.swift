import Foundation
import RxCodeCore

/// One selectable summarization provider, mirrored from the desktop's
/// `SummarizationProvider` enum. Sent as data rather than the enum itself
/// because the enum — and its hardware-dependent availability (Apple
/// Foundation Model) — lives in the desktop target.
public struct SummarizationProviderOption: Codable, Sendable, Equatable, Identifiable {
    /// Raw value of the desktop's `SummarizationProvider` case.
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct MobileSettingsSnapshot: Codable, Sendable, Equatable {
    public let selectedAgentProvider: AgentProvider
    public let selectedModel: String
    public let selectedACPClientId: String
    public let selectedEffort: String
    public let permissionMode: PermissionMode
    public let summarizationProvider: String
    public let summarizationProviderDisplayName: String
    public let openAISummarizationEndpoint: String
    public let openAISummarizationModel: String
    public let notificationsEnabled: Bool
    public let focusMode: Bool
    public let autoArchiveEnabled: Bool
    public let archiveRetentionDays: Int
    public let autoPreviewSettings: AttachmentAutoPreviewSettings
    public let availableEfforts: [String]
    /// Backend-reported thinking levels for each provider-qualified AgentModel.key.
    /// Older desktops only supplied the global union in availableEfforts.
    public let reasoningLevelsByModel: [String: [ReasoningLevel]]?
    /// All agent models discovered on the desktop, flattened across providers
    /// and ACP clients. Lets mobile show a model picker without re-deriving the
    /// list itself. Optional for backward compatibility with older desktops.
    public let availableModels: [AgentModel]?
    /// Model picker sections, mirroring the desktop layout — Claude Code,
    /// Codex, and one section per enabled ACP client. Lets mobile reproduce the
    /// desktop's per-ACP-client grouping instead of collapsing every ACP client
    /// into a single bucket. Optional for backward compatibility with older
    /// desktops, which sent only the flattened `availableModels` list.
    public let modelSections: [AgentModelSection]?
    /// Summarization providers the desktop currently offers, so mobile can
    /// render a provider picker without re-deriving hardware availability.
    /// Optional for backward compatibility with older desktops.
    public let availableSummarizationProviders: [SummarizationProviderOption]?
    /// Model identifiers fetched from the OpenAI-compatible summarization
    /// endpoint, so mobile can render a model picker. Empty/`nil` when the
    /// desktop hasn't fetched them yet (e.g. no API key configured).
    public let openAISummarizationModels: [String]?

    public init(
        selectedAgentProvider: AgentProvider,
        selectedModel: String,
        selectedACPClientId: String,
        selectedEffort: String,
        permissionMode: PermissionMode,
        summarizationProvider: String,
        summarizationProviderDisplayName: String,
        openAISummarizationEndpoint: String,
        openAISummarizationModel: String,
        notificationsEnabled: Bool,
        focusMode: Bool,
        autoArchiveEnabled: Bool,
        archiveRetentionDays: Int,
        autoPreviewSettings: AttachmentAutoPreviewSettings,
        availableEfforts: [String],
        reasoningLevelsByModel: [String: [ReasoningLevel]]? = nil,
        availableModels: [AgentModel]? = nil,
        modelSections: [AgentModelSection]? = nil,
        availableSummarizationProviders: [SummarizationProviderOption]? = nil,
        openAISummarizationModels: [String]? = nil
    ) {
        self.selectedAgentProvider = selectedAgentProvider
        self.selectedModel = selectedModel
        self.selectedACPClientId = selectedACPClientId
        self.selectedEffort = selectedEffort
        self.permissionMode = permissionMode
        self.summarizationProvider = summarizationProvider
        self.summarizationProviderDisplayName = summarizationProviderDisplayName
        self.openAISummarizationEndpoint = openAISummarizationEndpoint
        self.openAISummarizationModel = openAISummarizationModel
        self.notificationsEnabled = notificationsEnabled
        self.focusMode = focusMode
        self.autoArchiveEnabled = autoArchiveEnabled
        self.archiveRetentionDays = archiveRetentionDays
        self.autoPreviewSettings = autoPreviewSettings
        self.availableEfforts = availableEfforts
        self.reasoningLevelsByModel = reasoningLevelsByModel
        self.availableModels = availableModels
        self.modelSections = modelSections
        self.availableSummarizationProviders = availableSummarizationProviders
        self.openAISummarizationModels = openAISummarizationModels
    }

    private enum CodingKeys: String, CodingKey {
        case selectedAgentProvider, selectedModel, selectedACPClientId, selectedEffort
        case permissionMode, summarizationProvider, summarizationProviderDisplayName
        case openAISummarizationEndpoint, openAISummarizationModel
        case notificationsEnabled, focusMode, autoArchiveEnabled, archiveRetentionDays
        case autoPreviewSettings, availableEfforts, reasoningLevelsByModel, availableModels, modelSections
        case availableSummarizationProviders, openAISummarizationModels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedAgentProvider = try c.decode(AgentProvider.self, forKey: .selectedAgentProvider)
        selectedModel = try c.decode(String.self, forKey: .selectedModel)
        selectedACPClientId = try c.decode(String.self, forKey: .selectedACPClientId)
        selectedEffort = try c.decode(String.self, forKey: .selectedEffort)
        permissionMode = try c.decode(PermissionMode.self, forKey: .permissionMode)
        summarizationProvider = try c.decode(String.self, forKey: .summarizationProvider)
        summarizationProviderDisplayName = try c.decode(String.self, forKey: .summarizationProviderDisplayName)
        openAISummarizationEndpoint = try c.decode(String.self, forKey: .openAISummarizationEndpoint)
        openAISummarizationModel = try c.decode(String.self, forKey: .openAISummarizationModel)
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        focusMode = try c.decode(Bool.self, forKey: .focusMode)
        autoArchiveEnabled = try c.decode(Bool.self, forKey: .autoArchiveEnabled)
        archiveRetentionDays = try c.decode(Int.self, forKey: .archiveRetentionDays)
        autoPreviewSettings = try c.decode(AttachmentAutoPreviewSettings.self, forKey: .autoPreviewSettings)
        availableEfforts = try c.decode([String].self, forKey: .availableEfforts)
        reasoningLevelsByModel = try c.decodeIfPresent([String: [ReasoningLevel]].self, forKey: .reasoningLevelsByModel)
        availableModels = try c.decodeIfPresent([AgentModel].self, forKey: .availableModels)
        modelSections = try c.decodeIfPresent([AgentModelSection].self, forKey: .modelSections)
        availableSummarizationProviders = try c.decodeIfPresent(
            [SummarizationProviderOption].self, forKey: .availableSummarizationProviders
        )
        openAISummarizationModels = try c.decodeIfPresent(
            [String].self, forKey: .openAISummarizationModels
        )
    }
}

public struct MobileSettingsUpdatePayload: Codable, Sendable {
    public let selectedAgentProvider: AgentProvider?
    public let selectedModel: String?
    public let selectedACPClientId: String?
    public let selectedEffort: String?
    public let permissionMode: PermissionMode?
    /// Raw value of a `SummarizationProvider` case the user picked on mobile.
    public let summarizationProvider: String?
    /// Model identifier picked on mobile for the OpenAI-compatible endpoint.
    public let openAISummarizationModel: String?
    public let notificationsEnabled: Bool?
    public let focusMode: Bool?
    public let autoArchiveEnabled: Bool?
    public let archiveRetentionDays: Int?
    public let autoPreviewSettings: AttachmentAutoPreviewSettings?

    public init(
        selectedAgentProvider: AgentProvider? = nil,
        selectedModel: String? = nil,
        selectedACPClientId: String? = nil,
        selectedEffort: String? = nil,
        permissionMode: PermissionMode? = nil,
        summarizationProvider: String? = nil,
        openAISummarizationModel: String? = nil,
        notificationsEnabled: Bool? = nil,
        focusMode: Bool? = nil,
        autoArchiveEnabled: Bool? = nil,
        archiveRetentionDays: Int? = nil,
        autoPreviewSettings: AttachmentAutoPreviewSettings? = nil
    ) {
        self.selectedAgentProvider = selectedAgentProvider
        self.selectedModel = selectedModel
        self.selectedACPClientId = selectedACPClientId
        self.selectedEffort = selectedEffort
        self.permissionMode = permissionMode
        self.summarizationProvider = summarizationProvider
        self.openAISummarizationModel = openAISummarizationModel
        self.notificationsEnabled = notificationsEnabled
        self.focusMode = focusMode
        self.autoArchiveEnabled = autoArchiveEnabled
        self.archiveRetentionDays = archiveRetentionDays
        self.autoPreviewSettings = autoPreviewSettings
    }
}
