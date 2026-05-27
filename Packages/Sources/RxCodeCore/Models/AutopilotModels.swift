import Foundation

// MARK: - autopilot Repo DTO

/// Repository payload returned by `GET /api/v1/repos` on autopilot
/// (deployed at https://autopilot.rxlab.app). The macOS app no longer talks
/// to api.github.com directly — autopilot fans out across the signed-in
/// user's GitHub App installations and hands back a deduped list.
public struct AutopilotRepo: Identifiable, Codable, Sendable, Hashable {
    public let id: Int
    public let fullName: String
    public let name: String
    public let owner: String
    public let isPrivate: Bool
    public let defaultBranch: String?
    public let htmlUrl: String
    public let cloneUrl: String
    public let sshUrl: String
    public let updatedAt: String?
    public let description: String?

    public init(
        id: Int,
        fullName: String,
        name: String,
        owner: String,
        isPrivate: Bool,
        defaultBranch: String?,
        htmlUrl: String,
        cloneUrl: String,
        sshUrl: String,
        updatedAt: String?,
        description: String?
    ) {
        self.id = id
        self.fullName = fullName
        self.name = name
        self.owner = owner
        self.isPrivate = isPrivate
        self.defaultBranch = defaultBranch
        self.htmlUrl = htmlUrl
        self.cloneUrl = cloneUrl
        self.sshUrl = sshUrl
        self.updatedAt = updatedAt
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case fullName
        case name
        case owner
        case isPrivate = "private"
        case defaultBranch
        case htmlUrl
        case cloneUrl
        case sshUrl
        case updatedAt
        case description
    }
}

public struct AutopilotRepoListResponse: Codable, Sendable {
    public let items: [AutopilotRepo]
    public let pagination: Pagination?

    public struct Pagination: Codable, Sendable {
        public let nextCursor: String?
        public let hasMore: Bool

        public init(nextCursor: String?, hasMore: Bool) {
            self.nextCursor = nextCursor
            self.hasMore = hasMore
        }
    }

    public init(items: [AutopilotRepo], pagination: Pagination?) {
        self.items = items
        self.pagination = pagination
    }
}

// MARK: - GitHub App Installation DTOs

/// A GitHub App installation owned by the signed-in user, as recorded by
/// autopilot. The macOS app uses this to decide whether to surface the
/// "Install GitHub App" CTA in the import-repo sheet.
public struct AutopilotInstallation: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let installationId: Int
    public let accountLogin: String
    public let accountType: String
    public let accountAvatarUrl: String?
    public let repositorySelection: String

    public init(
        id: String,
        installationId: Int,
        accountLogin: String,
        accountType: String,
        accountAvatarUrl: String?,
        repositorySelection: String
    ) {
        self.id = id
        self.installationId = installationId
        self.accountLogin = accountLogin
        self.accountType = accountType
        self.accountAvatarUrl = accountAvatarUrl
        self.repositorySelection = repositorySelection
    }
}

/// Cheap "do you have any installations?" probe returned by
/// `GET /api/v1/installations/precheck`.
public struct AutopilotPrecheckResponse: Codable, Sendable {
    public let hasInstallation: Bool
    public let count: Int

    public init(hasInstallation: Bool, count: Int) {
        self.hasInstallation = hasInstallation
        self.count = count
    }
}

/// Reply from `GET /api/v1/installations/install-url`. The URL embeds a
/// signed `state` JWT tying the GitHub callback back to the requesting
/// rxauth user, so the install completes correctly even if the browser
/// is not signed in to autopilot.rxlab.app.
public struct AutopilotInstallUrlResponse: Codable, Sendable {
    public let url: String
    public let state: String
    public let expiresAt: String

    public init(url: String, state: String, expiresAt: String) {
        self.url = url
        self.state = state
        self.expiresAt = expiresAt
    }
}

