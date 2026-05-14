import Foundation

public struct MarketplacePlugin: Identifiable, Codable, Sendable, Hashable {
    public var id: String { "\(marketplace)/\(name)" }
    public let name: String
    public let description: String
    public let author: String
    public let category: String
    public let homepage: String
    public let marketplace: String
    public let sourceType: SourceType
    public let skillPaths: [String]

    public init(name: String, description: String, author: String, category: String,
                homepage: String, marketplace: String, sourceType: SourceType, skillPaths: [String]) {
        self.name = name
        self.description = description
        self.author = author
        self.category = category
        self.homepage = homepage
        self.marketplace = marketplace
        self.sourceType = sourceType
        self.skillPaths = skillPaths
    }

    public enum SourceType: String, Codable, Sendable {
        case local
        case url
        case gitSubdir = "git-subdir"
        case skillsBundle = "skills-bundle"
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
        default: return category.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    public var marketplaceLabel: String {
        switch marketplace {
        case "claude-plugins-official": return "Official Plugins"
        case "anthropic-agent-skills": return "Agent Skills"
        case "knowledge-work-plugins": return "Knowledge Work"
        case "financial-services-plugins": return "Financial Services"
        default: return marketplace
        }
    }

    public var installCommand: String {
        "/plugin install \(name)@\(marketplace)"
    }
}

public enum PluginInstallStatus: Sendable {
    case notInstalled
    case installing
    case installed
    case failed(String)
}
