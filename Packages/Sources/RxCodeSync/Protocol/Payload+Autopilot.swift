import Foundation
import RxCodeCore

// MARK: - Autopilot remote management (mobile → desktop)
//
// The desktop is the source of truth for every autopilot feature: it holds the
// rxlab bearer token and the passkey-derived secrets key, and is the only side
// that talks to `autopilot.rxlab.app`. Mobile mirrors the desktop's Autopilot
// settings tab by sending a single generic request/result pair over the
// E2E-encrypted relay channel; the desktop performs the action with its
// existing services and replies.
//
// One generic pair (`autopilotRequest` / `autopilotResult`) carries a `domain`
// + `operation` discriminator and a JSON `body` (a `RxCodeCore` DTO encoded to
// `Data`). Because `RxCodeCore` is linked on both sides, both encode/decode the
// same Codable model types — full type safety at the call sites with no
// per-operation `Payload` enum churn.

/// Autopilot sub-feature a request targets. Used for logging/grouping; the
/// desktop dispatches on `AutopilotOp`.
public enum AutopilotDomain: String, Codable, Sendable {
    case account
    case automation
    case repoSetup
    case secrets
    case ciUpdates
    case docs
    case release
    case project
}

/// Every autopilot operation, globally unique so the desktop can switch on it
/// directly. Grouped by domain in declaration order.
public enum AutopilotOp: String, Codable, Sendable {
    // Account
    case accountStatus

    // Shared repo picker (accessible GitHub repos with installation ids, used
    // by every "add repository" flow — mirrors the desktop add sheets which all
    // source `secrets.listManagedRepositories`).
    case listManagedRepos

    // Automation settings (schema-driven form)
    case automationSchema
    case automationValues
    case automationSave

    // Repo setup templates
    case repoSetupSchema
    case repoSetupList
    case repoSetupCreate
    case repoSetupUpdate
    case repoSetupDelete

    // Secrets — the desktop only relays opaque ciphertext; the phone derives the
    // KEK from the iCloud-synced passkey (WebAuthn PRF) and does all
    // encryption/decryption on-device, so plaintext never leaves the phone.
    case secretsEnrollmentStatus
    case secretsGetUserKey
    case secretsListEnvironments
    case secretsCreateEnvironment
    case secretsDeleteEnvironment
    case secretsListFiles
    case secretsGetBundle
    case secretsUpsertFile
    case secretsDeleteFile

    // CI auto-update
    case ciList
    case ciAdd
    case ciUpdateFrequency
    case ciDelete
    case ciHistory
    case ciTrigger
    case ciListPRs
    case ciClosePR

    // Docs
    case docsList
    case docsAdd
    case docsDelete
    case docsListDocuments
    case docsGetDocument
    case docsUploadDocument
    case docsDeleteDocument
    case docsCreateUploadToken
    case docsInstallGithubSecret

    // Release
    case releaseList
    case releaseAdd
    case releaseDelete
    case releaseListWorkflows
    case releaseDispatch
    case releaseInstallToken

    // Project context-menu actions — desktop-mediated so the Mac performs the
    // exact work its own project/briefing context menu does. `*Setup` ops set
    // the same AppState request the desktop menu sets (the Mac surfaces the
    // setup chat/sheet). For secrets download the phone decrypts on-device with
    // its own passkey-derived KEK and sends the plaintext over the E2E relay via
    // `projectSecretsWrite`; the Mac only writes the files into the project
    // folder (no passkey prompt on the Mac). `projectSecretsDownload` is the
    // legacy Mac-side-decrypt path, kept for wire compatibility.
    case projectAutopilotStatus
    case projectSecretsSetup
    case projectDocsSetup
    case projectDocsSearch
    case projectReleaseSetup
    case projectReleaseCreate
    case projectSecretsDownload
    case projectSecretsWrite
    case projectCreatePullRequest
}

/// Mobile → desktop: a single autopilot operation. `body` is a JSON-encoded
/// request DTO (nil for parameterless operations).
public struct AutopilotRequestPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let domain: String
    public let operation: String
    public let body: Data?

    public init(clientRequestID: UUID = UUID(), domain: AutopilotDomain, operation: AutopilotOp, body: Data? = nil) {
        self.clientRequestID = clientRequestID
        self.domain = domain.rawValue
        self.operation = operation.rawValue
        self.body = body
    }
}

/// Desktop → mobile: the result of an autopilot operation. `body` is a
/// JSON-encoded response DTO (nil for operations that return nothing, or on
/// failure).
public struct AutopilotResultPayload: Codable, Sendable {
    public let clientRequestID: UUID
    public let domain: String
    public let operation: String
    public let ok: Bool
    public let errorMessage: String?
    public let body: Data?

    public init(
        clientRequestID: UUID,
        domain: String,
        operation: String,
        ok: Bool,
        errorMessage: String? = nil,
        body: Data? = nil
    ) {
        self.clientRequestID = clientRequestID
        self.domain = domain
        self.operation = operation
        self.ok = ok
        self.errorMessage = errorMessage
        self.body = body
    }
}

// MARK: - Account

public struct AutopilotAccountStatus: Codable, Sendable {
    public let isSignedIn: Bool
    public let name: String?
    public let email: String?
    public let avatarURL: String?

    public init(isSignedIn: Bool, name: String? = nil, email: String? = nil, avatarURL: String? = nil) {
        self.isSignedIn = isSignedIn
        self.name = name
        self.email = email
        self.avatarURL = avatarURL
    }
}

// MARK: - Shared request bodies

/// Search + cursor for the shared accessible-repos picker.
public struct AutopilotReposQuery: Codable, Sendable {
    public let search: String?
    public let cursor: String?
    public init(search: String? = nil, cursor: String? = nil) {
        self.search = search
        self.cursor = cursor
    }
}

public struct AutopilotCursorQuery: Codable, Sendable {
    public let cursor: String?
    public init(cursor: String? = nil) { self.cursor = cursor }
}

/// Generic single-id body (template id, watched-repo id, docs/release-repo id).
public struct AutopilotIDBody: Codable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

/// Body addressing a docs/release repo by its internal id or `owner/repo`.
public struct AutopilotRepoIDBody: Codable, Sendable {
    public let repoId: String
    public init(repoId: String) { self.repoId = repoId }
}

// MARK: - Repo setup bodies

public struct AutopilotRepoSetupUpdateBody: Codable, Sendable {
    public let id: String
    public let input: RepoSetupTemplateInput
    public init(id: String, input: RepoSetupTemplateInput) {
        self.id = id
        self.input = input
    }
}

// MARK: - Secrets bodies / results

public struct AutopilotSecretsEnrollment: Codable, Sendable {
    public let enrolled: Bool
    public init(enrolled: Bool) { self.enrolled = enrolled }
}

public struct AutopilotSecretsRepoBody: Codable, Sendable {
    public let repo: String
    public init(repo: String) { self.repo = repo }
}

/// Create an environment from a key the phone already wrapped under its own
/// (passkey-derived) KEK. The desktop only forwards the body to the API; it
/// never derives a key or prompts for a passkey.
public struct AutopilotSecretsCreateEnvBody: Codable, Sendable {
    public let repo: String
    public let body: CreateEnvironmentBody
    public init(repo: String, body: CreateEnvironmentBody) {
        self.repo = repo
        self.body = body
    }
}

public struct AutopilotSecretsEnvRefBody: Codable, Sendable {
    public let repo: String
    public let envId: String
    public init(repo: String, envId: String) {
        self.repo = repo
        self.envId = envId
    }
}

/// Upsert a file the phone already encrypted under the environment DEK. The
/// desktop forwards the ciphertext body to the API verbatim.
public struct AutopilotSecretsUpsertFileBody: Codable, Sendable {
    public let repo: String
    public let envId: String
    public let file: UpsertFileBody
    public init(repo: String, envId: String, file: UpsertFileBody) {
        self.repo = repo
        self.envId = envId
        self.file = file
    }
}

public struct AutopilotSecretsDeleteFileBody: Codable, Sendable {
    public let repo: String
    public let envId: String
    public let fileId: String
    public init(repo: String, envId: String, fileId: String) {
        self.repo = repo
        self.envId = envId
        self.fileId = fileId
    }
}

/// One decrypted secret file. Produced on the phone after local decryption — it
/// is NOT a wire type and never crosses the relay.
public struct AutopilotSecretFilePlaintext: Sendable, Identifiable, Hashable {
    public let filename: String
    public let content: String
    public var id: String { filename }
    public init(filename: String, content: String) {
        self.filename = filename
        self.content = content
    }
}

// MARK: - CI auto-update bodies

public struct AutopilotCIFrequencyBody: Codable, Sendable {
    public let id: String
    public let frequency: CIScanFrequency
    public init(id: String, frequency: CIScanFrequency) {
        self.id = id
        self.frequency = frequency
    }
}

public struct AutopilotCIHistoryBody: Codable, Sendable {
    public let id: String
    public let limit: Int?
    public init(id: String, limit: Int? = nil) {
        self.id = id
        self.limit = limit
    }
}

public struct AutopilotCIClosePRBody: Codable, Sendable {
    public let id: String
    public let prNumber: Int
    public init(id: String, prNumber: Int) {
        self.id = id
        self.prNumber = prNumber
    }
}

// MARK: - Docs bodies

public struct AutopilotDocsDocBody: Codable, Sendable {
    public let repoId: String
    public let docId: String
    public init(repoId: String, docId: String) {
        self.repoId = repoId
        self.docId = docId
    }
}

public struct AutopilotDocsListDocumentsBody: Codable, Sendable {
    public let repoId: String
    public let cursor: String?
    public init(repoId: String, cursor: String? = nil) {
        self.repoId = repoId
        self.cursor = cursor
    }
}

public struct AutopilotDocsUploadBody: Codable, Sendable {
    public let repoId: String
    public let docId: String
    public let content: String
    public let originalLink: String?
    public init(repoId: String, docId: String, content: String, originalLink: String? = nil) {
        self.repoId = repoId
        self.docId = docId
        self.content = content
        self.originalLink = originalLink
    }
}

public struct AutopilotDocsCreateTokenBody: Codable, Sendable {
    public let repoId: String
    public let name: String?
    public init(repoId: String, name: String? = nil) {
        self.repoId = repoId
        self.name = name
    }
}

// MARK: - Release bodies / results

public struct AutopilotReleaseDispatchBody: Codable, Sendable {
    public let repoId: String
    public let request: ReleaseDispatchRequest
    public init(repoId: String, request: ReleaseDispatchRequest) {
        self.repoId = repoId
        self.request = request
    }
}

public struct AutopilotReleaseTokenBody: Codable, Sendable {
    public let repoId: String
    public let value: String
    public init(repoId: String, value: String) {
        self.repoId = repoId
        self.value = value
    }
}

/// Wire-friendly mirror of `ReleaseWorkflowInput` (which is `Decodable`-only and
/// so can't be re-encoded for the reply).
public struct MobileReleaseWorkflowInput: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let type: String
    public let description: String?
    public let required: Bool
    public let defaultString: String?
    public let defaultBool: Bool?
    public let options: [String]?
    public var id: String { name }

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

/// Wire-friendly mirror of `ReleaseWorkflow` (`Decodable`-only on the server DTO).
public struct MobileReleaseWorkflow: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let workflowPath: String
    public let workflowName: String?
    public let isSelected: Bool
    public let isReleaseWorkflow: Bool?
    public let hasWorkflowDispatch: Bool
    public let inputs: [MobileReleaseWorkflowInput]?

    public var displayName: String {
        if let workflowName, !workflowName.isEmpty { return workflowName }
        return workflowPath.split(separator: "/").last.map(String.init) ?? workflowPath
    }

    public init(
        id: String,
        workflowPath: String,
        workflowName: String? = nil,
        isSelected: Bool,
        isReleaseWorkflow: Bool? = nil,
        hasWorkflowDispatch: Bool,
        inputs: [MobileReleaseWorkflowInput]? = nil
    ) {
        self.id = id
        self.workflowPath = workflowPath
        self.workflowName = workflowName
        self.isSelected = isSelected
        self.isReleaseWorkflow = isReleaseWorkflow
        self.hasWorkflowDispatch = hasWorkflowDispatch
        self.inputs = inputs
    }
}

/// Array wrappers — keep result bodies as named objects for forward-compatible
/// decode and clearer logging than bare top-level JSON arrays.
public struct MobileReleaseWorkflowList: Codable, Sendable {
    public let items: [MobileReleaseWorkflow]
    public init(items: [MobileReleaseWorkflow]) { self.items = items }
}

public struct CIUpdateRunHistoryList: Codable, Sendable {
    public let items: [CIUpdateRunHistory]
    public init(items: [CIUpdateRunHistory]) { self.items = items }
}

public struct CIPullRequestList: Codable, Sendable {
    public let items: [CIPullRequest]
    public init(items: [CIPullRequest]) { self.items = items }
}

// MARK: - Project context-menu actions

/// Addresses a project by its local id; the desktop resolves it to the linked
/// GitHub repo and on-disk path.
public struct AutopilotProjectBody: Codable, Sendable {
    public let projectId: UUID
    public init(projectId: UUID) { self.projectId = projectId }
}

/// Addresses a project + branch. Used by `projectCreatePullRequest`, where the
/// desktop pushes the branch, generates the PR title/body from the branch
/// briefing, and opens the pull request (it holds the GitHub token + checkout).
public struct AutopilotProjectBranchBody: Codable, Sendable {
    public let projectId: UUID
    public let branch: String
    public init(projectId: UUID, branch: String) {
        self.projectId = projectId
        self.branch = branch
    }
}

/// Result of `projectCreatePullRequest`: the URL of the opened pull request.
public struct AutopilotPullRequestResult: Codable, Sendable {
    public let url: String
    public init(url: String) { self.url = url }
}

/// Per-project autopilot state powering the mobile context menu. Mirrors the
/// desktop's `projectHasSecrets` / `projectHasDocs` / `projectHasReleaseWorkflow`
/// checks so the phone can pick the same menu items (Download vs Set Up, etc.).
public struct AutopilotProjectStatus: Codable, Sendable {
    public let gitHubRepo: String?
    public let hasSecrets: Bool
    public let hasDocs: Bool
    public let hasRelease: Bool

    public init(gitHubRepo: String?, hasSecrets: Bool, hasDocs: Bool, hasRelease: Bool) {
        self.gitHubRepo = gitHubRepo
        self.hasSecrets = hasSecrets
        self.hasDocs = hasDocs
        self.hasRelease = hasRelease
    }
}

/// Ask the desktop to download + decrypt a secret environment and write its
/// files into the project's folder on the Mac. The Mac holds the passkey-derived
/// KEK and does the decryption, mirroring `AutopilotSecretsHook`'s desktop
/// download. `overwrite` clobbers files that already exist in the folder.
public struct AutopilotProjectSecretsDownloadBody: Codable, Sendable {
    public let projectId: UUID
    public let envId: String
    public let overwrite: Bool

    public init(projectId: UUID, envId: String, overwrite: Bool) {
        self.projectId = projectId
        self.envId = envId
        self.overwrite = overwrite
    }
}

/// Mobile → desktop: secret files the phone already decrypted on-device (using
/// its passkey-derived KEK — the same iCloud-synced credential the Mac uses) to
/// be written into the project's folder on the Mac. The plaintext travels only
/// inside the E2E-encrypted relay channel to the paired Mac, which writes the
/// files without ever prompting for a passkey. Replaces the Mac-side-decrypt
/// `projectSecretsDownload` for mobile-initiated downloads.
public struct AutopilotProjectSecretsWriteBody: Codable, Sendable {
    public let projectId: UUID
    public let files: [Plaintext]
    public let overwrite: Bool

    /// One already-decrypted file. A wire type (unlike `AutopilotSecretFilePlaintext`,
    /// which is on-device only) because it crosses the encrypted relay.
    public struct Plaintext: Codable, Sendable {
        public let filename: String
        public let content: String
        public init(filename: String, content: String) {
            self.filename = filename
            self.content = content
        }
    }

    public init(projectId: UUID, files: [Plaintext], overwrite: Bool) {
        self.projectId = projectId
        self.files = files
        self.overwrite = overwrite
    }
}

/// Result of `projectSecretsDownload` / `projectSecretsWrite`: filenames actually
/// written, plus the files skipped because they already existed (only when
/// `overwrite` was false). The phone re-issues with `overwrite: true` to clobber
/// the conflicts.
public struct AutopilotProjectSecretsDownloadResult: Codable, Sendable {
    public let written: [String]
    public let conflicts: [String]

    public init(written: [String], conflicts: [String]) {
        self.written = written
        self.conflicts = conflicts
    }
}
