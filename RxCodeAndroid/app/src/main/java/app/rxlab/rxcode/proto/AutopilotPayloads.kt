package app.rxlab.rxcode.proto

import kotlinx.serialization.Serializable
import java.util.UUID

/**
 * Autopilot remote-management wire types. Mirrors
 * `RxCodeSync/Protocol/Payload+Autopilot.swift`.
 *
 * The desktop is the source of truth for every autopilot feature (it holds the
 * rxlab bearer token and the passkey-derived secrets key, and is the only side
 * that talks to `autopilot.rxlab.app`). Mobile mirrors the desktop's Autopilot
 * settings tab by sending a single generic request/result pair over the
 * E2E-encrypted relay channel; the desktop performs the action and replies.
 *
 * One generic pair (`autopilot_request` / `autopilot_result`) carries a
 * `domain` + `operation` discriminator and a JSON `body`. On the wire the body
 * is a base64 string because Swift's `JSONEncoder` encodes `Data` as base64 by
 * default — see [AutopilotCodec] for the encode/decode helpers.
 */

/** Autopilot sub-feature a request targets (used for logging/grouping). */
enum class AutopilotDomain(val wire: String) {
    ACCOUNT("account"),
    AUTOMATION("automation"),
    REPO_SETUP("repoSetup"),
    SECRETS("secrets"),
    CI_UPDATES("ciUpdates"),
    DOCS("docs"),
    RELEASE("release"),
    PROJECT("project"),
    SEARCH("search"),
}

/** Every autopilot operation, globally unique so the desktop can switch on it. */
enum class AutopilotOp(val wire: String) {
    // Account
    ACCOUNT_STATUS("accountStatus"),
    LIST_MANAGED_REPOS("listManagedRepos"),
    CLONE_MANAGED_REPO("cloneManagedRepo"),
    INSTALL_GITHUB_APP_URL("installGitHubAppUrl"),

    // Automation settings (schema-driven form)
    AUTOMATION_SCHEMA("automationSchema"),
    AUTOMATION_VALUES("automationValues"),
    AUTOMATION_SAVE("automationSave"),

    // Repo setup templates
    REPO_SETUP_SCHEMA("repoSetupSchema"),
    REPO_SETUP_LIST("repoSetupList"),
    REPO_SETUP_CREATE("repoSetupCreate"),
    REPO_SETUP_UPDATE("repoSetupUpdate"),
    REPO_SETUP_DELETE("repoSetupDelete"),

    // Secrets — desktop relays opaque ciphertext only.
    SECRETS_ENROLLMENT_STATUS("secretsEnrollmentStatus"),
    SECRETS_GET_USER_KEY("secretsGetUserKey"),
    SECRETS_LIST_ENVIRONMENTS("secretsListEnvironments"),
    SECRETS_CREATE_ENVIRONMENT("secretsCreateEnvironment"),
    SECRETS_DELETE_ENVIRONMENT("secretsDeleteEnvironment"),
    SECRETS_LIST_FILES("secretsListFiles"),
    SECRETS_GET_BUNDLE("secretsGetBundle"),
    SECRETS_UPSERT_FILE("secretsUpsertFile"),
    SECRETS_DELETE_FILE("secretsDeleteFile"),

    // CI auto-update
    CI_LIST("ciList"),
    CI_ADD("ciAdd"),
    CI_UPDATE_FREQUENCY("ciUpdateFrequency"),
    CI_DELETE("ciDelete"),
    CI_HISTORY("ciHistory"),
    CI_TRIGGER("ciTrigger"),
    CI_LIST_PRS("ciListPRs"),
    CI_CLOSE_PR("ciClosePR"),

    // Docs
    DOCS_LIST("docsList"),
    DOCS_ADD("docsAdd"),
    DOCS_DELETE("docsDelete"),
    DOCS_LIST_DOCUMENTS("docsListDocuments"),
    DOCS_GET_DOCUMENT("docsGetDocument"),
    DOCS_UPLOAD_DOCUMENT("docsUploadDocument"),
    DOCS_DELETE_DOCUMENT("docsDeleteDocument"),
    DOCS_CREATE_UPLOAD_TOKEN("docsCreateUploadToken"),
    DOCS_INSTALL_GITHUB_SECRET("docsInstallGithubSecret"),

    // Release
    RELEASE_LIST("releaseList"),
    RELEASE_ADD("releaseAdd"),
    RELEASE_DELETE("releaseDelete"),
    RELEASE_LIST_WORKFLOWS("releaseListWorkflows"),
    RELEASE_DISPATCH("releaseDispatch"),
    RELEASE_INSTALL_TOKEN("releaseInstallToken"),

    // Project context-menu actions — desktop-mediated so the Mac performs the
    // exact work its own project/briefing context menu does. The `*Setup` ops
    // ask the Mac to surface its setup chat/sheet; secrets download decrypts
    // on-device then relays plaintext via `projectSecretsWrite`.
    PROJECT_AUTOPILOT_STATUS("projectAutopilotStatus"),
    PROJECT_SECRETS_SETUP("projectSecretsSetup"),
    PROJECT_DOCS_SETUP("projectDocsSetup"),
    PROJECT_DOCS_SEARCH("projectDocsSearch"),
    PROJECT_RELEASE_SETUP("projectReleaseSetup"),
    PROJECT_RELEASE_CREATE("projectReleaseCreate"),
    PROJECT_SECRETS_DOWNLOAD("projectSecretsDownload"),
    PROJECT_SECRETS_WRITE("projectSecretsWrite"),
    PROJECT_CREATE_PULL_REQUEST("projectCreatePullRequest"),

    // Code review (desktop-mediated): spawn a `[Code Review]` thread on the Mac.
    PROJECT_CREATE_CODE_REVIEW("projectCreateCodeReview"),
    THREAD_CREATE_CODE_REVIEW("threadCreateCodeReview"),

    // Global search — one call returns thread matches AND published-docs matches.
    SEARCH_THREADS_AND_DOCS("searchThreadsAndDocs"),
}

/**
 * Mobile → desktop: a single autopilot operation. `body` is a base64-encoded
 * JSON request DTO (null for parameterless operations).
 */
@Serializable
data class AutopilotRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val domain: String,
    val operation: String,
    val body: String? = null,
)

/**
 * Desktop → mobile: the result of an autopilot operation. `body` is a
 * base64-encoded JSON response DTO (null for operations that return nothing,
 * or on failure).
 */
@Serializable
data class AutopilotResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val domain: String,
    val operation: String,
    val ok: Boolean,
    val errorMessage: String? = null,
    val body: String? = null,
)

// MARK: - Shared request bodies

/** Search + cursor for the shared accessible-repos picker. */
@Serializable
data class AutopilotReposQuery(val search: String? = null, val cursor: String? = null)

@Serializable
data class AutopilotCursorQuery(val cursor: String? = null)

/** Generic single-id body (template id, watched-repo id, docs/release-repo id). */
@Serializable
data class AutopilotIDBody(val id: String)

/** Body addressing a docs/release repo by its internal id or `owner/repo`. */
@Serializable
data class AutopilotRepoIDBody(val repoId: String)

// MARK: - Repo setup bodies

@Serializable
data class AutopilotRepoSetupUpdateBody(val id: String, val input: RepoSetupTemplateInput)

// MARK: - Secrets bodies

@Serializable
data class AutopilotSecretsRepoBody(val repo: String)

@Serializable
data class AutopilotSecretsCreateEnvBody(val repo: String, val body: CreateEnvironmentBody)

@Serializable
data class AutopilotSecretsEnvRefBody(val repo: String, val envId: String)

@Serializable
data class AutopilotSecretsUpsertFileBody(val repo: String, val envId: String, val file: UpsertFileBody)

@Serializable
data class AutopilotSecretsDeleteFileBody(val repo: String, val envId: String, val fileId: String)

/**
 * One decrypted secret file. Produced on the phone after local decryption — it
 * is NOT a wire type and never crosses the relay.
 */
data class AutopilotSecretFilePlaintext(val filename: String, val content: String)

// MARK: - CI auto-update bodies

@Serializable
data class AutopilotCIFrequencyBody(val id: String, val frequency: CIScanFrequency)

@Serializable
data class AutopilotCIHistoryBody(val id: String, val limit: Int? = null)

@Serializable
data class AutopilotCIClosePRBody(val id: String, val prNumber: Int)

// MARK: - Docs bodies

@Serializable
data class AutopilotDocsDocBody(val repoId: String, val docId: String)

@Serializable
data class AutopilotDocsListDocumentsBody(val repoId: String, val cursor: String? = null)

@Serializable
data class AutopilotDocsUploadBody(
    val repoId: String,
    val docId: String,
    val content: String,
    val originalLink: String? = null,
)

@Serializable
data class AutopilotDocsCreateTokenBody(val repoId: String, val name: String? = null)

// MARK: - Release bodies

@Serializable
data class AutopilotReleaseDispatchBody(val repoId: String, val request: ReleaseDispatchRequest)

@Serializable
data class AutopilotReleaseTokenBody(val repoId: String, val value: String)

// MARK: - Project context-menu bodies

/** Addresses a project by id (status + the desktop-mediated setup actions). */
@Serializable
data class AutopilotProjectBody(
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
)

/** Addresses a project + branch. Used by `projectCreatePullRequest` and `projectCreateCodeReview`. */
@Serializable
data class AutopilotProjectBranchBody(
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val branch: String,
)

/** Addresses a single thread by id. Used by `threadCreateCodeReview`. */
@Serializable
data class AutopilotThreadBody(val sessionId: String)

/**
 * Already-decrypted secret files for `projectSecretsWrite`: the phone decrypts
 * the chosen environment on-device, then relays plaintext over the E2E channel
 * for the Mac to write into the project folder.
 */
@Serializable
data class AutopilotProjectSecretsWriteBody(
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val files: List<Plaintext>,
    val overwrite: Boolean,
) {
    @Serializable
    data class Plaintext(val filename: String, val content: String)
}

// MARK: - Global search body

/** A single query run across both on-device threads and published docs. */
@Serializable
data class AutopilotSearchBody(val query: String, val limit: Int? = null)

// MARK: - Result list wrappers

@Serializable
data class MobileReleaseWorkflowList(val items: List<MobileReleaseWorkflow>)

@Serializable
data class CIUpdateRunHistoryList(val items: List<CIUpdateRunHistory>)

@Serializable
data class CIPullRequestList(val items: List<CIPullRequest>)
