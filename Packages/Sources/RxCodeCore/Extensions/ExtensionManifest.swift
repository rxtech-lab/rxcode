import Foundation

/// The manifest embedded in both the contributor application and its extension.
public struct ExtensionManifest: Codable, Hashable, Sendable {
    public static let apiVersion = "2.0"
    public static let resourceName = "RxCodeExtension.json"

    public let id: String
    public let name: String
    public let version: String
    public let pluginAPI: String
    public let readme: String
    public let permissions: [ExtensionPermission]
    public let contributes: Contributions

    public struct Contributions: Codable, Hashable, Sendable {
        public let usageProviders: [UsageProvider]?
        public let usageCard: Bool?
        public let usageDetail: Bool?
        public let inspectorPanel: Panel?
        public let settings: Bool?

        enum CodingKeys: String, CodingKey {
            case usageProviders = "usage.provider"
            case usageCard = "usage.card"
            case usageDetail = "usage.detail"
            case inspectorPanel = "inspector.panel"
            case settings
        }

        public var sceneIDs: Set<String> {
            var scenes = Set<String>()
            if usageCard == true { scenes.insert("usage-card") }
            if usageDetail == true { scenes.insert("usage-detail") }
            if inspectorPanel != nil { scenes.insert("inspector") }
            if settings == true { scenes.insert("settings") }
            return scenes
        }
    }

    public struct UsageProvider: Codable, Hashable, Sendable {
        public let pluginID: String
        public let title: String
        public let authentication: String?
        public let fields: [String: String]?
    }

    public struct Panel: Codable, Hashable, Sendable {
        public let title: String
        public let symbol: String
    }

    public var effectivePermissions: [ExtensionPermission] {
        let declared = Set(permissions.map(\.id))
        return [.projectRead, .storage].filter { !declared.contains($0) }
            .map { ExtensionPermission(id: $0) } + permissions
    }

    /// Supply the scene list during activation and the installed provider owners during installation.
    public func validate(
        supportedAPI: String = Self.apiVersion,
        reportedScenes: Set<String>? = nil,
        providerOwners: [String: String] = [:]
    ) throws {
        guard Self.isDNSName(id), id.contains(".") else { throw ValidationError.invalidID }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version.range(of: #"\A[0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.-]+)*\z"#, options: .regularExpression) != nil,
              readme == "README.md" else { throw ValidationError.invalidMetadata }
        guard pluginAPI == supportedAPI else { throw ValidationError.incompatibleAPI(pluginAPI) }
        var seenPermissions = Set<ExtensionPermission.ID>()
        for permission in permissions {
            guard seenPermissions.insert(permission.id).inserted else {
                throw ValidationError.invalidPermission(permission.id)
            }
            try permission.validate()
        }

        var seenProviders = Set<String>()
        for provider in contributes.usageProviders ?? [] {
            guard provider.pluginID.range(of: #"\A[a-z0-9]+(?:-[a-z0-9]+)*\z"#, options: .regularExpression) != nil,
                  !provider.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.invalidMetadata
            }
            guard seenProviders.insert(provider.pluginID).inserted,
                  providerOwners[provider.pluginID].map({ $0 == id }) ?? true else {
                throw ValidationError.providerConflict(provider.pluginID)
            }
        }

        if let reportedScenes, reportedScenes != contributes.sceneIDs { throw ValidationError.sceneMismatch }
    }

    static func isDNSName(_ name: String) -> Bool {
        guard name.utf8.count <= 253 else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard let first = label.utf8.first, let last = label.utf8.last,
                  first != 45, last != 45, label.utf8.count <= 63 else { return false }
            return label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidID, invalidMetadata, sceneMismatch
        case incompatibleAPI(String), providerConflict(String), invalidPermission(ExtensionPermission.ID)

        public var errorDescription: String? {
            switch self {
            case .invalidID: "The extension ID must be a lowercase reverse-DNS name."
            case .invalidMetadata: "The extension manifest contains invalid metadata."
            case .sceneMismatch: "The extension's scenes differ from its manifest."
            case .incompatibleAPI(let api): "The extension requires plugin API \(api)."
            case .providerConflict(let id): "Another provider already claims \(id)."
            case .invalidPermission(let id): "Invalid scope or duplicate declaration for \(id.rawValue)."
            }
        }
    }
}
