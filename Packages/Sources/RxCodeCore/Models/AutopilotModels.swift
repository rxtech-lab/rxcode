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

// MARK: - CI Status DTOs

/// One repo+branch lookup sent in the `POST /api/v1/ci-status/batch` body.
/// `branch` is optional; when nil autopilot reports the latest run on any
/// branch and echoes back which branch it matched.
public struct CIStatusQuery: Codable, Sendable, Hashable {
    public let owner: String
    public let repo: String
    public let branch: String?

    public init(owner: String, repo: String, branch: String?) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
    }
}

public struct CIStatusBatchRequest: Codable, Sendable {
    public let repos: [CIStatusQuery]

    public init(repos: [CIStatusQuery]) {
        self.repos = repos
    }
}

/// Aggregated CI state for a repo+branch. Decodes leniently — unknown raw
/// values fall back to `.unknown` so a server-side addition never breaks
/// the client.
public enum CIOverallState: String, Codable, Sendable, Hashable {
    case success
    case failure
    case pending
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CIOverallState(rawValue: raw) ?? .unknown
    }
}

/// Latest run for a single workflow definition on the queried branch.
public struct CIWorkflowStatus: Codable, Sendable, Hashable {
    public let workflowName: String?
    public let workflowId: Int?
    public let status: String?
    public let conclusion: String?
    public let htmlUrl: String?
    public let runNumber: Int?
    public let updatedAt: String?

    public init(
        workflowName: String?,
        workflowId: Int?,
        status: String?,
        conclusion: String?,
        htmlUrl: String?,
        runNumber: Int?,
        updatedAt: String?
    ) {
        self.workflowName = workflowName
        self.workflowId = workflowId
        self.status = status
        self.conclusion = conclusion
        self.htmlUrl = htmlUrl
        self.runNumber = runNumber
        self.updatedAt = updatedAt
    }
}

/// A failing workflow surfaced for quick linking in the UI / fix prompt.
public struct CIFailingWorkflow: Codable, Sendable, Hashable {
    public let workflowName: String?
    public let htmlUrl: String?

    public init(workflowName: String?, htmlUrl: String?) {
        self.workflowName = workflowName
        self.htmlUrl = htmlUrl
    }
}

/// Per-repo result from `POST /api/v1/ci-status/batch`.
public struct ProjectCIStatus: Codable, Sendable, Hashable {
    public let owner: String
    public let repo: String
    public let branch: String?
    public let found: Bool
    public let overallState: CIOverallState
    public let lastUpdated: String?
    public let headSha: String?
    public let prNumber: Int?
    public let workflows: [CIWorkflowStatus]
    public let failing: [CIFailingWorkflow]

    public init(
        owner: String,
        repo: String,
        branch: String?,
        found: Bool,
        overallState: CIOverallState,
        lastUpdated: String?,
        headSha: String?,
        prNumber: Int?,
        workflows: [CIWorkflowStatus],
        failing: [CIFailingWorkflow]
    ) {
        self.owner = owner
        self.repo = repo
        self.branch = branch
        self.found = found
        self.overallState = overallState
        self.lastUpdated = lastUpdated
        self.headSha = headSha
        self.prNumber = prNumber
        self.workflows = workflows
        self.failing = failing
    }
}

public struct CIStatusBatchResponse: Codable, Sendable {
    public let results: [ProjectCIStatus]

    public init(results: [ProjectCIStatus]) {
        self.results = results
    }
}

