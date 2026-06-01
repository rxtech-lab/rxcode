package app.rxlab.rxcode.state

import app.rxlab.rxcode.proto.AddDocsRepoBody
import app.rxlab.rxcode.proto.AddReleaseRepoBody
import app.rxlab.rxcode.proto.AddWatchedRepoBody
import app.rxlab.rxcode.proto.AutopilotAccountStatus
import app.rxlab.rxcode.proto.AutopilotCIClosePRBody
import app.rxlab.rxcode.proto.AutopilotCIFrequencyBody
import app.rxlab.rxcode.proto.AutopilotCIHistoryBody
import app.rxlab.rxcode.proto.AutopilotCursorQuery
import app.rxlab.rxcode.proto.AutopilotDocsCreateTokenBody
import app.rxlab.rxcode.proto.AutopilotDocsDocBody
import app.rxlab.rxcode.proto.AutopilotDocsListDocumentsBody
import app.rxlab.rxcode.proto.AutopilotDocsUploadBody
import app.rxlab.rxcode.proto.AutopilotDomain
import app.rxlab.rxcode.proto.AutopilotIDBody
import app.rxlab.rxcode.proto.AutopilotOp
import app.rxlab.rxcode.proto.AutopilotReleaseDispatchBody
import app.rxlab.rxcode.proto.AutopilotReleaseTokenBody
import app.rxlab.rxcode.proto.AutopilotReposQuery
import app.rxlab.rxcode.proto.AutopilotRepoIDBody
import app.rxlab.rxcode.proto.AutopilotRepoSetupUpdateBody
import app.rxlab.rxcode.proto.AutopilotRequestPayload
import app.rxlab.rxcode.proto.AutopilotResultPayload
import app.rxlab.rxcode.proto.AutopilotSecretsCreateEnvBody
import app.rxlab.rxcode.proto.AutopilotSecretsDeleteFileBody
import app.rxlab.rxcode.proto.AutopilotSecretsEnrollment
import app.rxlab.rxcode.proto.AutopilotSecretsEnvRefBody
import app.rxlab.rxcode.proto.AutopilotSecretsRepoBody
import app.rxlab.rxcode.proto.AutopilotSecretsUpsertFileBody
import app.rxlab.rxcode.proto.CIPullRequest
import app.rxlab.rxcode.proto.CIPullRequestList
import app.rxlab.rxcode.proto.CIScanFrequency
import app.rxlab.rxcode.proto.CITriggerResponse
import app.rxlab.rxcode.proto.CIUpdateRunHistory
import app.rxlab.rxcode.proto.CIUpdateRunHistoryList
import app.rxlab.rxcode.proto.CreateEnvironmentBody
import app.rxlab.rxcode.proto.DocsDocumentDetail
import app.rxlab.rxcode.proto.DocsDocumentList
import app.rxlab.rxcode.proto.DocsGithubSecretResult
import app.rxlab.rxcode.proto.DocsRepoListResponse
import app.rxlab.rxcode.proto.DocsUploadResult
import app.rxlab.rxcode.proto.DocsUploadToken
import app.rxlab.rxcode.proto.MobileReleaseWorkflow
import app.rxlab.rxcode.proto.MobileReleaseWorkflowList
import app.rxlab.rxcode.proto.Payload
import app.rxlab.rxcode.proto.PreferencesValues
import app.rxlab.rxcode.proto.ReleaseDispatchRequest
import app.rxlab.rxcode.proto.ReleaseDispatchResult
import app.rxlab.rxcode.proto.ReleaseGithubSecretResult
import app.rxlab.rxcode.proto.ReleaseRepoListResponse
import app.rxlab.rxcode.proto.RepoSetupTemplate
import app.rxlab.rxcode.proto.RepoSetupTemplateInput
import app.rxlab.rxcode.proto.RepoSetupTemplateList
import app.rxlab.rxcode.proto.RxJson
import app.rxlab.rxcode.proto.SchemaEnvelope
import app.rxlab.rxcode.proto.SecretsBundle
import app.rxlab.rxcode.proto.SecretsEnvironment
import app.rxlab.rxcode.proto.SecretsEnvironmentList
import app.rxlab.rxcode.proto.SecretsFileList
import app.rxlab.rxcode.proto.SecretsFileMeta
import app.rxlab.rxcode.proto.SecretsManagedRepoPage
import app.rxlab.rxcode.proto.SecretsUserKey
import app.rxlab.rxcode.proto.UpsertFileBody
import app.rxlab.rxcode.proto.WatchedRepoPage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Errors surfaced by the autopilot remote-call layer. Message is user-facing. */
class AutopilotException(message: String) : Exception(message)

/**
 * Mirrors `MobileAppState+Autopilot.swift`: a single generic request/result
 * round trip over the encrypted relay, correlated by `clientRequestID`, plus
 * typed wrappers for every autopilot operation.
 *
 * The desktop is the source of truth and the only side that talks to
 * `autopilot.rxlab.app`; for secrets the desktop relays opaque ciphertext only
 * — encryption/decryption happens on-device (see [SecretsManager]).
 */
class AutopilotService(
    private val send: suspend (Payload, String) -> Boolean,
    private val activeDesktopHex: () -> String?,
) {
    private val pending = ConcurrentHashMap<UUID, CompletableDeferred<AutopilotResultPayload>>()

    /** Routed here by [MobileAppState] when an `autopilot_result` arrives. */
    fun handleResult(result: AutopilotResultPayload) {
        pending.remove(result.clientRequestID)?.complete(result)
    }

    /** Fail every in-flight request, e.g. when the active desktop changes. */
    fun cancelAll(reason: String) {
        val snapshot = pending.values.toList()
        pending.clear()
        snapshot.forEach { it.completeExceptionally(AutopilotException(reason)) }
    }

    // MARK: - Generic round trip

    private suspend fun rawCall(
        domain: AutopilotDomain,
        op: AutopilotOp,
        bodyBase64: String?,
    ): AutopilotResultPayload {
        val hex = activeDesktopHex()
            ?: throw AutopilotException("Connect an online Mac to use Autopilot.")
        val payload = AutopilotRequestPayload(domain = domain.wire, operation = op.wire, body = bodyBase64)
        val deferred = CompletableDeferred<AutopilotResultPayload>()
        pending[payload.clientRequestID] = deferred
        val sent = try {
            send(Payload.AutopilotRequest(payload), hex)
        } catch (t: Throwable) {
            pending.remove(payload.clientRequestID)
            throw AutopilotException(t.message ?: "Failed to reach your Mac.")
        }
        if (!sent) {
            pending.remove(payload.clientRequestID)
            throw AutopilotException("Couldn't send the request. Check your Mac and try again.")
        }
        val result = withTimeoutOrNull(AUTOPILOT_TIMEOUT_MS) { deferred.await() }
        if (result == null) {
            pending.remove(payload.clientRequestID)
            throw AutopilotException("Request timed out. Check your Mac and try again.")
        }
        if (!result.ok) {
            throw AutopilotException(result.errorMessage ?: "The Mac could not complete the request.")
        }
        return result
    }

    private inline fun <reified Req> encodeBody(body: Req): String =
        Base64.getEncoder().encodeToString(
            RxJson.encodeToString(body).toByteArray(Charsets.UTF_8)
        )

    private inline fun <reified Res> decodeResult(result: AutopilotResultPayload): Res {
        val body = result.body ?: throw AutopilotException("The Mac returned an empty response.")
        val json = String(Base64.getDecoder().decode(body), Charsets.UTF_8)
        return RxJson.decodeFromString(json)
    }

    // MARK: - Account

    suspend fun accountStatus(): AutopilotAccountStatus =
        decodeResult(rawCall(AutopilotDomain.ACCOUNT, AutopilotOp.ACCOUNT_STATUS, null))

    suspend fun listRepos(search: String?, cursor: String? = null): SecretsManagedRepoPage =
        decodeResult(
            rawCall(
                AutopilotDomain.ACCOUNT, AutopilotOp.LIST_MANAGED_REPOS,
                encodeBody(AutopilotReposQuery(search = search, cursor = cursor)),
            )
        )

    // MARK: - Automation

    suspend fun automationSchema(): SchemaEnvelope =
        decodeResult(rawCall(AutopilotDomain.AUTOMATION, AutopilotOp.AUTOMATION_SCHEMA, null))

    suspend fun automationValues(): PreferencesValues =
        decodeResult(rawCall(AutopilotDomain.AUTOMATION, AutopilotOp.AUTOMATION_VALUES, null))

    suspend fun saveAutomationValues(values: JsonElement): PreferencesValues =
        decodeResult(
            rawCall(
                AutopilotDomain.AUTOMATION, AutopilotOp.AUTOMATION_SAVE,
                encodeBody(PreferencesValues(values)),
            )
        )

    // MARK: - Repo setup

    suspend fun repoSetupSchema(): SchemaEnvelope =
        decodeResult(rawCall(AutopilotDomain.REPO_SETUP, AutopilotOp.REPO_SETUP_SCHEMA, null))

    suspend fun repoSetupTemplates(): List<RepoSetupTemplate> =
        decodeResult<RepoSetupTemplateList>(
            rawCall(AutopilotDomain.REPO_SETUP, AutopilotOp.REPO_SETUP_LIST, null)
        ).items

    suspend fun createRepoSetupTemplate(input: RepoSetupTemplateInput): RepoSetupTemplate =
        decodeResult(
            rawCall(AutopilotDomain.REPO_SETUP, AutopilotOp.REPO_SETUP_CREATE, encodeBody(input))
        )

    suspend fun updateRepoSetupTemplate(id: String, input: RepoSetupTemplateInput): RepoSetupTemplate =
        decodeResult(
            rawCall(
                AutopilotDomain.REPO_SETUP, AutopilotOp.REPO_SETUP_UPDATE,
                encodeBody(AutopilotRepoSetupUpdateBody(id, input)),
            )
        )

    suspend fun deleteRepoSetupTemplate(id: String) {
        rawCall(AutopilotDomain.REPO_SETUP, AutopilotOp.REPO_SETUP_DELETE, encodeBody(AutopilotIDBody(id)))
    }

    // MARK: - Secrets (relay only — crypto orchestration lives in SecretsManager)

    suspend fun secretsEnrollmentStatus(): Boolean =
        decodeResult<AutopilotSecretsEnrollment>(
            rawCall(AutopilotDomain.SECRETS, AutopilotOp.SECRETS_ENROLLMENT_STATUS, null)
        ).enrolled

    suspend fun secretsUserKey(): SecretsUserKey =
        decodeResult(rawCall(AutopilotDomain.SECRETS, AutopilotOp.SECRETS_GET_USER_KEY, null))

    suspend fun listSecretEnvironments(repo: String): List<SecretsEnvironment> =
        decodeResult<SecretsEnvironmentList>(
            rawCall(
                AutopilotDomain.SECRETS, AutopilotOp.SECRETS_LIST_ENVIRONMENTS,
                encodeBody(AutopilotSecretsRepoBody(repo)),
            )
        ).items

    suspend fun createSecretEnvironment(repo: String, body: CreateEnvironmentBody) {
        rawCall(
            AutopilotDomain.SECRETS, AutopilotOp.SECRETS_CREATE_ENVIRONMENT,
            encodeBody(AutopilotSecretsCreateEnvBody(repo, body)),
        )
    }

    suspend fun deleteSecretEnvironment(repo: String, envId: String) {
        rawCall(
            AutopilotDomain.SECRETS, AutopilotOp.SECRETS_DELETE_ENVIRONMENT,
            encodeBody(AutopilotSecretsEnvRefBody(repo, envId)),
        )
    }

    suspend fun listSecretFiles(repo: String, envId: String): List<SecretsFileMeta> =
        decodeResult<SecretsFileList>(
            rawCall(
                AutopilotDomain.SECRETS, AutopilotOp.SECRETS_LIST_FILES,
                encodeBody(AutopilotSecretsEnvRefBody(repo, envId)),
            )
        ).items

    suspend fun secretsBundle(repo: String, envId: String): SecretsBundle =
        decodeResult(
            rawCall(
                AutopilotDomain.SECRETS, AutopilotOp.SECRETS_GET_BUNDLE,
                encodeBody(AutopilotSecretsEnvRefBody(repo, envId)),
            )
        )

    suspend fun upsertSecretFile(repo: String, envId: String, file: UpsertFileBody) {
        rawCall(
            AutopilotDomain.SECRETS, AutopilotOp.SECRETS_UPSERT_FILE,
            encodeBody(AutopilotSecretsUpsertFileBody(repo, envId, file)),
        )
    }

    suspend fun deleteSecretFile(repo: String, envId: String, fileId: String) {
        rawCall(
            AutopilotDomain.SECRETS, AutopilotOp.SECRETS_DELETE_FILE,
            encodeBody(AutopilotSecretsDeleteFileBody(repo, envId, fileId)),
        )
    }

    // MARK: - CI auto-update

    suspend fun listWatchedRepos(cursor: String? = null): WatchedRepoPage =
        decodeResult(
            rawCall(AutopilotDomain.CI_UPDATES, AutopilotOp.CI_LIST, encodeBody(AutopilotCursorQuery(cursor)))
        )

    suspend fun addWatchedRepo(body: AddWatchedRepoBody) {
        rawCall(AutopilotDomain.CI_UPDATES, AutopilotOp.CI_ADD, encodeBody(body))
    }

    suspend fun updateWatchedRepoFrequency(id: String, frequency: CIScanFrequency) {
        rawCall(
            AutopilotDomain.CI_UPDATES, AutopilotOp.CI_UPDATE_FREQUENCY,
            encodeBody(AutopilotCIFrequencyBody(id, frequency)),
        )
    }

    suspend fun deleteWatchedRepo(id: String) {
        rawCall(AutopilotDomain.CI_UPDATES, AutopilotOp.CI_DELETE, encodeBody(AutopilotIDBody(id)))
    }

    suspend fun watchedRepoHistory(id: String, limit: Int? = null): List<CIUpdateRunHistory> =
        decodeResult<CIUpdateRunHistoryList>(
            rawCall(AutopilotDomain.CI_UPDATES, AutopilotOp.CI_HISTORY, encodeBody(AutopilotCIHistoryBody(id, limit)))
        ).items

    suspend fun triggerWatchedRepoScan(id: String): CITriggerResponse =
        decodeResult(
            rawCall(AutopilotDomain.CI_UPDATES, AutopilotOp.CI_TRIGGER, encodeBody(AutopilotIDBody(id)))
        )

    suspend fun watchedRepoPullRequests(id: String): List<CIPullRequest> =
        decodeResult<CIPullRequestList>(
            rawCall(AutopilotDomain.CI_UPDATES, AutopilotOp.CI_LIST_PRS, encodeBody(AutopilotIDBody(id)))
        ).items

    suspend fun closeWatchedRepoPR(id: String, prNumber: Int) {
        rawCall(AutopilotDomain.CI_UPDATES, AutopilotOp.CI_CLOSE_PR, encodeBody(AutopilotCIClosePRBody(id, prNumber)))
    }

    // MARK: - Docs

    suspend fun listDocsRepos(search: String? = null, cursor: String? = null): DocsRepoListResponse =
        decodeResult(
            rawCall(AutopilotDomain.DOCS, AutopilotOp.DOCS_LIST, encodeBody(AutopilotReposQuery(search, cursor)))
        )

    suspend fun addDocsRepo(body: AddDocsRepoBody) {
        rawCall(AutopilotDomain.DOCS, AutopilotOp.DOCS_ADD, encodeBody(body))
    }

    suspend fun deleteDocsRepo(id: String) {
        rawCall(AutopilotDomain.DOCS, AutopilotOp.DOCS_DELETE, encodeBody(AutopilotIDBody(id)))
    }

    suspend fun listDocuments(repoId: String, cursor: String? = null): DocsDocumentList =
        decodeResult(
            rawCall(
                AutopilotDomain.DOCS, AutopilotOp.DOCS_LIST_DOCUMENTS,
                encodeBody(AutopilotDocsListDocumentsBody(repoId, cursor)),
            )
        )

    suspend fun getDocument(repoId: String, docId: String): DocsDocumentDetail =
        decodeResult(
            rawCall(
                AutopilotDomain.DOCS, AutopilotOp.DOCS_GET_DOCUMENT,
                encodeBody(AutopilotDocsDocBody(repoId, docId)),
            )
        )

    suspend fun uploadDocument(
        repoId: String,
        docId: String,
        content: String,
        originalLink: String?,
    ): DocsUploadResult =
        decodeResult(
            rawCall(
                AutopilotDomain.DOCS, AutopilotOp.DOCS_UPLOAD_DOCUMENT,
                encodeBody(AutopilotDocsUploadBody(repoId, docId, content, originalLink)),
            )
        )

    suspend fun deleteDocument(repoId: String, docId: String) {
        rawCall(AutopilotDomain.DOCS, AutopilotOp.DOCS_DELETE_DOCUMENT, encodeBody(AutopilotDocsDocBody(repoId, docId)))
    }

    suspend fun createDocsUploadToken(repoId: String, name: String?): DocsUploadToken =
        decodeResult(
            rawCall(
                AutopilotDomain.DOCS, AutopilotOp.DOCS_CREATE_UPLOAD_TOKEN,
                encodeBody(AutopilotDocsCreateTokenBody(repoId, name)),
            )
        )

    suspend fun installDocsGithubSecret(repoId: String): DocsGithubSecretResult =
        decodeResult(
            rawCall(
                AutopilotDomain.DOCS, AutopilotOp.DOCS_INSTALL_GITHUB_SECRET,
                encodeBody(AutopilotRepoIDBody(repoId)),
            )
        )

    // MARK: - Release

    suspend fun listReleaseRepos(cursor: String? = null): ReleaseRepoListResponse =
        decodeResult(
            rawCall(AutopilotDomain.RELEASE, AutopilotOp.RELEASE_LIST, encodeBody(AutopilotCursorQuery(cursor)))
        )

    suspend fun addReleaseRepo(body: AddReleaseRepoBody) {
        rawCall(AutopilotDomain.RELEASE, AutopilotOp.RELEASE_ADD, encodeBody(body))
    }

    suspend fun deleteReleaseRepo(id: String) {
        rawCall(AutopilotDomain.RELEASE, AutopilotOp.RELEASE_DELETE, encodeBody(AutopilotIDBody(id)))
    }

    suspend fun listReleaseWorkflows(repoId: String): List<MobileReleaseWorkflow> =
        decodeResult<MobileReleaseWorkflowList>(
            rawCall(
                AutopilotDomain.RELEASE, AutopilotOp.RELEASE_LIST_WORKFLOWS,
                encodeBody(AutopilotRepoIDBody(repoId)),
            )
        ).items

    suspend fun dispatchRelease(repoId: String, request: ReleaseDispatchRequest): ReleaseDispatchResult =
        decodeResult(
            rawCall(
                AutopilotDomain.RELEASE, AutopilotOp.RELEASE_DISPATCH,
                encodeBody(AutopilotReleaseDispatchBody(repoId, request)),
            )
        )

    suspend fun installReleaseToken(repoId: String, value: String): ReleaseGithubSecretResult =
        decodeResult(
            rawCall(
                AutopilotDomain.RELEASE, AutopilotOp.RELEASE_INSTALL_TOKEN,
                encodeBody(AutopilotReleaseTokenBody(repoId, value)),
            )
        )

    companion object {
        /** Longer ceiling than config calls: scans/secret minting take a while. */
        private const val AUTOPILOT_TIMEOUT_MS = 45_000L
    }
}
