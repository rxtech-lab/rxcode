import Foundation

public struct MarketplacePlugin: Identifiable, Codable, Sendable, Hashable {
    public var id: String { "\(marketplace)/\(name)" }
    public let name: String
    public let description: String
    public let author: String
    public let category: String
    public let homepage: String
    public let marketplace: String
    public let marketplaceSource: MarketplaceSource?
    public let sourceType: SourceType
    public let skillPaths: [String]

    public init(name: String, description: String, author: String, category: String,
                homepage: String, marketplace: String, marketplaceSource: MarketplaceSource? = nil,
                sourceType: SourceType, skillPaths: [String]) {
        self.name = name
        self.description = description
        self.author = author
        self.category = category
        self.homepage = homepage
        self.marketplace = marketplace
        self.marketplaceSource = marketplaceSource
        self.sourceType = sourceType
        self.skillPaths = skillPaths
    }

    public enum SourceType: String, Codable, Sendable {
        case local
        case url
        case gitSubdir = "git-subdir"
        case skillsBundle = "skills-bundle"
        case agentSkill = "agent-skill"
    }

    public var categoryLabel: String {
        switch category {
        case "official": return "Official Plugin"
        case "development": return "Development Tools"
        case "productivity": return "Productivity"
        case "location": return "Location Services"
        case "agent-skills": return "Agent Skills"
        case "knowledge-work": return "Knowledge Work"
        case "financial-services": return "Financial Services"
        case "codex-curated": return "Codex Curated"
        default: return category.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    public var marketplaceLabel: String {
        switch marketplace {
        case "claude-plugins-official": return "Official Plugins"
        case "anthropic-agent-skills": return "Agent Skills"
        case "knowledge-work-plugins": return "Knowledge Work"
        case "financial-services-plugins": return "Financial Services"
        case "openai-skills-curated": return "Codex Curated"
        default: return marketplace
        }
    }

    public var installCommand: String {
        "Install \(name) from \(marketplace)"
    }
}

public struct MarketplaceSource: Codable, Sendable, Hashable {
    public let owner: String
    public let repo: String
    public let ref: String?

    public init(owner: String, repo: String, ref: String? = nil) {
        self.owner = owner
        self.repo = repo
        self.ref = ref
    }

    public var codexSource: String {
        if let ref, !ref.isEmpty {
            return "\(owner)/\(repo)@\(ref)"
        }
        return "\(owner)/\(repo)"
    }
}

public struct MarketplaceCustomSource: Codable, Sendable, Hashable, Identifiable {
    public var id: String { source.codexSource }
    public var source: MarketplaceSource
    public var defaultCategory: String
    public var addedAt: Date

    public init(
        source: MarketplaceSource,
        defaultCategory: String = "custom",
        addedAt: Date = Date()
    ) {
        self.source = source
        self.defaultCategory = defaultCategory
        self.addedAt = addedAt
    }

    public var displayName: String {
        source.codexSource
    }
}

public struct MarketplacePluginRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(marketplace)/\(name)" }
    public var name: String
    public var marketplace: String
    public var summary: String?
    public var category: String?
    public var marketplaceSource: MarketplaceSource?
    public var sourceType: MarketplacePlugin.SourceType?
    public var skillPaths: [String]?
    public var instructions: String?
    public var installedAt: Date
    public var isGloballyEnabled: Bool
    public var enabledProviders: Set<AgentProvider>

    public init(
        name: String,
        marketplace: String,
        summary: String? = nil,
        category: String? = nil,
        marketplaceSource: MarketplaceSource?,
        sourceType: MarketplacePlugin.SourceType? = nil,
        skillPaths: [String]? = nil,
        instructions: String? = nil,
        installedAt: Date = Date(),
        isGloballyEnabled: Bool = true,
        enabledProviders: Set<AgentProvider> = Set(AgentProvider.allCases)
    ) {
        self.name = name
        self.marketplace = marketplace
        self.summary = summary
        self.category = category
        self.marketplaceSource = marketplaceSource
        self.sourceType = sourceType
        self.skillPaths = skillPaths
        self.instructions = instructions
        self.installedAt = installedAt
        self.isGloballyEnabled = isGloballyEnabled
        self.enabledProviders = enabledProviders
    }

    public func isEnabled(for provider: AgentProvider) -> Bool {
        isGloballyEnabled && enabledProviders.contains(provider)
    }
}

public struct MarketplacePluginConfiguration: Codable, Sendable, Equatable {
    public var version: Int
    public var plugins: [MarketplacePluginRecord]
    public var customSources: [MarketplaceCustomSource]

    public init(
        version: Int = 2,
        plugins: [MarketplacePluginRecord] = [],
        customSources: [MarketplaceCustomSource] = []
    ) {
        self.version = version
        self.plugins = plugins
        self.customSources = customSources
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case plugins
        case customSources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        plugins = try container.decodeIfPresent([MarketplacePluginRecord].self, forKey: .plugins) ?? []
        customSources = try container.decodeIfPresent([MarketplaceCustomSource].self, forKey: .customSources) ?? []
    }
}

public enum PluginInstallStatus: Sendable {
    case notInstalled
    case installing
    case installed
    case failed(String)
}
