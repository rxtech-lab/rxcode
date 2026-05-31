import Foundation
import RxCodeCore

// MARK: - Skills / ACP / MCP remote management

/// Mobile asks the desktop for the skill marketplace catalog. `forceRefresh`
/// bypasses the desktop's 5-minute marketplace cache.
public struct SkillCatalogRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let forceRefresh: Bool

    public init(clientRequestID: UUID = UUID(), forceRefresh: Bool = false) {
        self.clientRequestID = clientRequestID
        self.forceRefresh = forceRefresh
    }
}

/// One marketplace plugin flattened from the desktop's `MarketplacePlugin`
/// plus its current install state. `id` mirrors `MarketplacePlugin.id`.
public struct MobileSkillPlugin: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let author: String
    public let category: String
    public let categoryLabel: String
    public let marketplace: String
    public let marketplaceLabel: String
    public let homepage: String
    public let isInstalled: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        author: String,
        category: String,
        categoryLabel: String,
        marketplace: String,
        marketplaceLabel: String,
        homepage: String,
        isInstalled: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.author = author
        self.category = category
        self.categoryLabel = categoryLabel
        self.marketplace = marketplace
        self.marketplaceLabel = marketplaceLabel
        self.homepage = homepage
        self.isInstalled = isInstalled
    }
}

public struct MobileSkillSource: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct SkillCatalogResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let ok: Bool
    public let errorMessage: String?
    public let plugins: [MobileSkillPlugin]
    public let sources: [MobileSkillSource]

    public init(
        clientRequestID: UUID,
        ok: Bool,
        errorMessage: String? = nil,
        plugins: [MobileSkillPlugin] = [],
        sources: [MobileSkillSource] = []
    ) {
        self.clientRequestID = clientRequestID
        self.ok = ok
        self.errorMessage = errorMessage
        self.plugins = plugins
        self.sources = sources
    }
}

/// Mobile asks the desktop to install or remove a marketplace skill. `pluginID`
/// is the catalog id; the desktop re-resolves the authoritative plugin from its
/// own freshly-fetched catalog.
public struct SkillMutationRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case install
        case uninstall
    }

    public let clientRequestID: UUID
    public let operation: Operation
    public let pluginID: String

    public init(clientRequestID: UUID = UUID(), operation: Operation, pluginID: String) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.pluginID = pluginID
    }
}

public struct SkillMutationResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let operation: SkillMutationRequestPayload.Operation
    public let pluginID: String
    public let ok: Bool
    public let errorMessage: String?
    public let plugins: [MobileSkillPlugin]
    public let sources: [MobileSkillSource]

    public init(
        clientRequestID: UUID,
        operation: SkillMutationRequestPayload.Operation,
        pluginID: String,
        ok: Bool,
        errorMessage: String? = nil,
        plugins: [MobileSkillPlugin] = [],
        sources: [MobileSkillSource] = []
    ) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.pluginID = pluginID
        self.ok = ok
        self.errorMessage = errorMessage
        self.plugins = plugins
        self.sources = sources
    }
}

public struct SkillSourceMutationRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case add
        case remove
    }

    public let clientRequestID: UUID
    public let operation: Operation
    public let sourceID: String?
    public let gitURL: String?
    public let ref: String?

    public init(
        clientRequestID: UUID = UUID(),
        operation: Operation,
        sourceID: String? = nil,
        gitURL: String? = nil,
        ref: String? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.sourceID = sourceID
        self.gitURL = gitURL
        self.ref = ref
    }
}

public struct SkillSourceMutationResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let operation: SkillSourceMutationRequestPayload.Operation
    public let sourceID: String?
    public let ok: Bool
    public let errorMessage: String?
    public let plugins: [MobileSkillPlugin]
    public let sources: [MobileSkillSource]

    public init(
        clientRequestID: UUID,
        operation: SkillSourceMutationRequestPayload.Operation,
        sourceID: String? = nil,
        ok: Bool,
        errorMessage: String? = nil,
        plugins: [MobileSkillPlugin] = [],
        sources: [MobileSkillSource] = []
    ) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.sourceID = sourceID
        self.ok = ok
        self.errorMessage = errorMessage
        self.plugins = plugins
        self.sources = sources
    }
}

/// Mobile asks the desktop for the ACP agent registry plus installed clients.
public struct ACPRegistryRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let forceRefresh: Bool

    public init(clientRequestID: UUID = UUID(), forceRefresh: Bool = false) {
        self.clientRequestID = clientRequestID
        self.forceRefresh = forceRefresh
    }
}

/// A registry agent flattened from the desktop's `ACPRegistryAgent`, plus
/// whether a matching client is already installed locally.
public struct MobileACPRegistryAgent: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    public let authors: [String]
    public let license: String?
    public let website: String?
    public let iconURL: String?
    public let isInstalled: Bool
    public let hasBinary: Bool
    public let hasNpx: Bool
    public let hasUvx: Bool

    public init(
        id: String,
        name: String,
        version: String,
        summary: String,
        authors: [String] = [],
        license: String? = nil,
        website: String? = nil,
        iconURL: String? = nil,
        isInstalled: Bool,
        hasBinary: Bool,
        hasNpx: Bool,
        hasUvx: Bool
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.summary = summary
        self.authors = authors
        self.license = license
        self.website = website
        self.iconURL = iconURL
        self.isInstalled = isInstalled
        self.hasBinary = hasBinary
        self.hasNpx = hasNpx
        self.hasUvx = hasUvx
    }
}

/// An installed ACP client mirrored from the desktop's `ACPClientSpec`.
public struct MobileACPClient: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let registryId: String?
    public let displayName: String
    public let enabled: Bool
    public let launchKind: String
    public let modelCount: Int
    public let iconURL: String?

    public init(
        id: String,
        registryId: String? = nil,
        displayName: String,
        enabled: Bool,
        launchKind: String,
        modelCount: Int,
        iconURL: String? = nil
    ) {
        self.id = id
        self.registryId = registryId
        self.displayName = displayName
        self.enabled = enabled
        self.launchKind = launchKind
        self.modelCount = modelCount
        self.iconURL = iconURL
    }
}

public struct ACPRegistryResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let ok: Bool
    public let errorMessage: String?
    public let registryAgents: [MobileACPRegistryAgent]
    public let installedClients: [MobileACPClient]

    public init(
        clientRequestID: UUID,
        ok: Bool,
        errorMessage: String? = nil,
        registryAgents: [MobileACPRegistryAgent] = [],
        installedClients: [MobileACPClient] = []
    ) {
        self.clientRequestID = clientRequestID
        self.ok = ok
        self.errorMessage = errorMessage
        self.registryAgents = registryAgents
        self.installedClients = installedClients
    }
}

/// Mobile asks the desktop to install an ACP agent from the registry, remove an
/// installed client, or toggle a client's enabled flag.
public struct ACPMutationRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case install
        case uninstall
        case setEnabled
    }

    public let clientRequestID: UUID
    public let operation: Operation
    public let registryAgentID: String?
    public let clientID: String?
    public let enabled: Bool?

    public init(
        clientRequestID: UUID = UUID(),
        operation: Operation,
        registryAgentID: String? = nil,
        clientID: String? = nil,
        enabled: Bool? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.registryAgentID = registryAgentID
        self.clientID = clientID
        self.enabled = enabled
    }
}

public struct ACPMutationResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let operation: ACPMutationRequestPayload.Operation
    public let ok: Bool
    public let errorMessage: String?
    public let registryAgents: [MobileACPRegistryAgent]
    public let installedClients: [MobileACPClient]

    public init(
        clientRequestID: UUID,
        operation: ACPMutationRequestPayload.Operation,
        ok: Bool,
        errorMessage: String? = nil,
        registryAgents: [MobileACPRegistryAgent] = [],
        installedClients: [MobileACPClient] = []
    ) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.ok = ok
        self.errorMessage = errorMessage
        self.registryAgents = registryAgents
        self.installedClients = installedClients
    }
}

/// Mobile asks the desktop for the configured global MCP servers.
public struct MCPConfigRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID

    public init(clientRequestID: UUID = UUID()) {
        self.clientRequestID = clientRequestID
    }
}

/// A plain key/value pair for MCP environment variables and headers. The
/// desktop's `MCPKeyValue` carries a non-Codable UUID, so the wire uses this.
public struct MobileMCPKeyValue: Codable, Sendable, Equatable, Hashable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One global MCP server flattened from the desktop's `MCPServerRecord`.
public struct MobileMCPServer: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }

    public let name: String
    public let transport: String
    public let url: String?
    public let command: String?
    public let args: [String]
    public let env: [MobileMCPKeyValue]
    public let headers: [MobileMCPKeyValue]
    public let isGloballyEnabled: Bool
    public let endpoint: String

    public init(
        name: String,
        transport: String,
        url: String? = nil,
        command: String? = nil,
        args: [String] = [],
        env: [MobileMCPKeyValue] = [],
        headers: [MobileMCPKeyValue] = [],
        isGloballyEnabled: Bool,
        endpoint: String
    ) {
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.env = env
        self.headers = headers
        self.isGloballyEnabled = isGloballyEnabled
        self.endpoint = endpoint
    }
}

public struct MCPConfigResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let ok: Bool
    public let errorMessage: String?
    public let servers: [MobileMCPServer]

    public init(
        clientRequestID: UUID,
        ok: Bool,
        errorMessage: String? = nil,
        servers: [MobileMCPServer] = []
    ) {
        self.clientRequestID = clientRequestID
        self.ok = ok
        self.errorMessage = errorMessage
        self.servers = servers
    }
}

/// Mobile asks the desktop to add/upsert, remove, or toggle a global MCP server.
public struct MCPMutationRequestPayload: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case add
        case remove
        case setEnabled
    }

    public let clientRequestID: UUID
    public let operation: Operation
    public let serverName: String
    public let server: MobileMCPServer?
    public let enabled: Bool?

    public init(
        clientRequestID: UUID = UUID(),
        operation: Operation,
        serverName: String,
        server: MobileMCPServer? = nil,
        enabled: Bool? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.serverName = serverName
        self.server = server
        self.enabled = enabled
    }
}

public struct MCPMutationResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let operation: MCPMutationRequestPayload.Operation
    public let serverName: String
    public let ok: Bool
    public let errorMessage: String?
    public let servers: [MobileMCPServer]

    public init(
        clientRequestID: UUID,
        operation: MCPMutationRequestPayload.Operation,
        serverName: String,
        ok: Bool,
        errorMessage: String? = nil,
        servers: [MobileMCPServer] = []
    ) {
        self.clientRequestID = clientRequestID
        self.operation = operation
        self.serverName = serverName
        self.ok = ok
        self.errorMessage = errorMessage
        self.servers = servers
    }
}

public struct MobileBranchBriefing: Codable, Sendable, Identifiable, Equatable {
    public var id: String { "\(projectId.uuidString)::\(branch)" }

    public let projectId: UUID
    public let branch: String
    public let briefing: String
    public let updatedAt: Date

    public init(projectId: UUID, branch: String, briefing: String, updatedAt: Date) {
        self.projectId = projectId
        self.branch = branch
        self.briefing = briefing
        self.updatedAt = updatedAt
    }
}

public struct MobileProjectCIStatus: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID { projectId }

    public let projectId: UUID
    public let status: ProjectCIStatus

    public init(projectId: UUID, status: ProjectCIStatus) {
        self.projectId = projectId
        self.status = status
    }
}

public struct MobileThreadSummary: Codable, Sendable, Identifiable, Equatable {
    public var id: String { sessionId }

    public let sessionId: String
    public let projectId: UUID
    public let branch: String
    public let title: String
    public let summary: String
    public let updatedAt: Date

    public init(
        sessionId: String,
        projectId: UUID,
        branch: String,
        title: String,
        summary: String,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.branch = branch
        self.title = title
        self.summary = summary
        self.updatedAt = updatedAt
    }
}

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
        case autoPreviewSettings, availableEfforts, availableModels, modelSections
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
