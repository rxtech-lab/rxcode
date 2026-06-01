import Foundation

// Codable DTOs mirroring github-pm's `/api/v1/release-repositories/*` JSON
// shapes. Field names match the server responses (Drizzle column names);
// extra fields decode harmlessly and uncertain fields are optional so a
// contract drift degrades gracefully rather than failing the whole decode.

// MARK: - Repositories

/// A release-managed repository from `GET /api/v1/release-repositories`. Rows
/// are returned verbatim from the `releaseRepository` table, so dates arrive as
/// ISO strings.
public struct ReleaseRepo: Codable, Sendable, Identifiable, Hashable {
    /// Internal release-repository UUID.
    public let id: String
    public let installationId: Int?
    public let repositoryId: Int?
    public let repositoryFullName: String
    public let owner: String?
    public let repo: String?
    public let lastScannedAt: String?
    /// Cached latest release tag (e.g. `v1.4.2`), if any release exists yet.
    public let latestReleaseTag: String?
    public let latestReleaseAt: String?
    public let versionsListVisibility: String?
    public let createdAt: String?
    public let updatedAt: String?

    public var fullName: String { repositoryFullName }

    public init(
        id: String,
        installationId: Int? = nil,
        repositoryId: Int? = nil,
        repositoryFullName: String,
        owner: String? = nil,
        repo: String? = nil,
        lastScannedAt: String? = nil,
        latestReleaseTag: String? = nil,
        latestReleaseAt: String? = nil,
        versionsListVisibility: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.id = id
        self.installationId = installationId
        self.repositoryId = repositoryId
        self.repositoryFullName = repositoryFullName
        self.owner = owner
        self.repo = repo
        self.lastScannedAt = lastScannedAt
        self.latestReleaseTag = latestReleaseTag
        self.latestReleaseAt = latestReleaseAt
        self.versionsListVisibility = versionsListVisibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ReleaseRepoListResponse: Codable, Sendable {
    public let items: [ReleaseRepo]
    public let pagination: Pagination?

    public struct Pagination: Codable, Sendable {
        public let nextCursor: String?
        public let hasMore: Bool
    }
}

/// Body for `POST /api/v1/release-repositories` (register a repo for releases).
public struct AddReleaseRepoBody: Codable, Sendable {
    public let installationId: Int
    public let repositoryId: Int
    public let repositoryFullName: String

    public init(installationId: Int, repositoryId: Int, repositoryFullName: String) {
        self.installationId = installationId
        self.repositoryId = repositoryId
        self.repositoryFullName = repositoryFullName
    }
}

/// `{ id }` returned by `POST /api/v1/release-repositories`.
public struct ReleaseIDResponse: Codable, Sendable {
    public let id: String
}

// MARK: - Batch status

/// Body for the batch status endpoint `POST /api/v1/release-repositories/status`.
public struct ReleaseRepoStatusRequest: Codable, Sendable {
    public let repositories: [String]

    public init(repositories: [String]) { self.repositories = repositories }
}

/// Per-repo release status from `POST /api/v1/release-repositories/status`. A
/// repo "has the release workflow set up" when it's registered **and** has a
/// selected dispatchable workflow (`hasReleaseWorkflow`). `latestVersion` is the
/// cached `latestReleaseTag`.
public struct ReleaseRepoStatus: Codable, Sendable, Hashable {
    /// `owner/repo` the status is for.
    public let fullName: String
    /// Registered with the release service.
    public let isManaged: Bool
    /// Registered AND has a selected dispatchable release workflow.
    public let hasReleaseWorkflow: Bool
    /// Latest published release tag, if any.
    public let latestVersion: String?
    /// Internal release-repository UUID, when managed.
    public let releaseRepositoryId: String?

    public init(
        fullName: String,
        isManaged: Bool,
        hasReleaseWorkflow: Bool,
        latestVersion: String? = nil,
        releaseRepositoryId: String? = nil
    ) {
        self.fullName = fullName
        self.isManaged = isManaged
        self.hasReleaseWorkflow = hasReleaseWorkflow
        self.latestVersion = latestVersion
        self.releaseRepositoryId = releaseRepositoryId
    }
}

// MARK: - Workflows

/// One parsed `workflow_dispatch` input from a release workflow's YAML. Matches
/// github-pm's `WorkflowInput`. Decode-only: the app reads these to build the
/// dispatch form and never sends them back.
public struct ReleaseWorkflowInput: Decodable, Sendable, Hashable, Identifiable {
    public let name: String
    /// `string | boolean | choice | environment`.
    public let type: String
    public let description: String?
    public let required: Bool
    /// The YAML `default` flattened to a string (booleans become `"true"`/`"false"`).
    public let defaultString: String?
    /// The YAML `default` as a bool, when the input is a boolean.
    public let defaultBool: Bool?
    /// Options for `choice` inputs.
    public let options: [String]?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, type, description, required, options
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(String.self, forKey: .type)) ?? "string"
        description = try? c.decode(String.self, forKey: .description)
        required = (try? c.decode(Bool.self, forKey: .required)) ?? false
        options = try? c.decode([String].self, forKey: .options)
        // The server's `default` is `string | boolean`; accept either.
        if let b = try? c.decode(Bool.self, forKey: .defaultValue) {
            defaultBool = b
            defaultString = b ? "true" : "false"
        } else if let s = try? c.decode(String.self, forKey: .defaultValue) {
            defaultString = s
            defaultBool = (s == "true")
        } else {
            defaultString = nil
            defaultBool = nil
        }
    }

    public init(
        name: String,
        type: String,
        description: String? = nil,
        required: Bool = false,
        defaultString: String? = nil,
        defaultBool: Bool? = nil,
        options: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.defaultString = defaultString
        self.defaultBool = defaultBool
        self.options = options
    }
}

/// A scanned workflow from `GET /api/v1/release-repositories/{id}/workflows`
/// (raw `releaseWorkflow` rows). `content` (raw YAML) is omitted from app use.
public struct ReleaseWorkflow: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let releaseRepositoryId: String?
    public let workflowPath: String
    public let workflowName: String?
    /// User has marked this workflow as the release workflow.
    public let isSelected: Bool
    /// AI classification: looks like a release workflow.
    public let isReleaseWorkflow: Bool?
    /// Can be triggered via `workflow_dispatch`.
    public let hasWorkflowDispatch: Bool
    public let inputs: [ReleaseWorkflowInput]?
    public let createdAt: String?
    public let updatedAt: String?

    /// Display name falls back to the file name.
    public var displayName: String {
        if let workflowName, !workflowName.isEmpty { return workflowName }
        return workflowPath.split(separator: "/").last.map(String.init) ?? workflowPath
    }

    enum CodingKeys: String, CodingKey {
        case id, releaseRepositoryId, workflowPath, workflowName
        case isSelected, isReleaseWorkflow, hasWorkflowDispatch, inputs
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        releaseRepositoryId = try? c.decode(String.self, forKey: .releaseRepositoryId)
        workflowPath = try c.decode(String.self, forKey: .workflowPath)
        workflowName = try? c.decode(String.self, forKey: .workflowName)
        isSelected = (try? c.decode(Bool.self, forKey: .isSelected)) ?? false
        isReleaseWorkflow = try? c.decode(Bool.self, forKey: .isReleaseWorkflow)
        hasWorkflowDispatch = (try? c.decode(Bool.self, forKey: .hasWorkflowDispatch)) ?? false
        inputs = try? c.decode([ReleaseWorkflowInput].self, forKey: .inputs)
        createdAt = try? c.decode(String.self, forKey: .createdAt)
        updatedAt = try? c.decode(String.self, forKey: .updatedAt)
    }
}

// MARK: - Dispatch

/// Body for `POST /api/v1/release-repositories/{id}/dispatch`. GitHub
/// `workflow_dispatch` inputs are always strings, so booleans are sent as
/// `"true"`/`"false"`.
public struct ReleaseDispatchRequest: Codable, Sendable {
    public let workflowId: String
    public let branch: String
    public let inputs: [String: String]

    public init(workflowId: String, branch: String, inputs: [String: String] = [:]) {
        self.workflowId = workflowId
        self.branch = branch
        self.inputs = inputs
    }
}

/// Result of a dispatch. On success the server returns `dispatchId` +
/// `workflowRunUrl` (the repo's Actions page).
public struct ReleaseDispatchResult: Codable, Sendable {
    public let success: Bool?
    public let dispatchId: String?
    public let workflowRunUrl: String?
    public let error: String?
}

// MARK: - GitHub secret (RELEASE_TOKEN)

/// Body for `POST /api/v1/release-repositories/{id}/github-secret`. Unlike docs
/// (which mints a token server-side), the release token is user-supplied and
/// installed as the `RELEASE_TOKEN` Actions secret.
public struct InstallReleaseTokenBody: Codable, Sendable {
    public let value: String

    public init(value: String) { self.value = value }
}

/// Result of installing the `RELEASE_TOKEN` secret.
public struct ReleaseGithubSecretResult: Codable, Sendable {
    public let secretName: String
    public let repositoryFullName: String

    public init(secretName: String, repositoryFullName: String) {
        self.secretName = secretName
        self.repositoryFullName = repositoryFullName
    }
}
