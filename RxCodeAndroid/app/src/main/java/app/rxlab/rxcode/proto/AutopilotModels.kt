package app.rxlab.rxcode.proto

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.time.Instant
import java.util.UUID

/**
 * Domain models for the autopilot remote-management feature. Mirrors the
 * `RxCodeCore` Swift types. JSON keys match the Swift `Codable` encoding;
 * `@SerialName` is applied wherever the wire key differs from the Kotlin name.
 *
 * JSON-Schema-shaped values (schema/uiSchema/preferences/merge settings/
 * rulesets) are kept as raw [JsonElement] — the Swift side models them with a
 * generic `JSONValue` enum and we want the same lossless passthrough.
 */

// MARK: - Flexible timestamp

/**
 * Tolerant timestamp: the desktop encodes ISO-8601 strings, but some upstream
 * GitHub payloads carry epoch-milliseconds numbers (and either can be null).
 * Mirrors Swift `FlexibleTimestamp`.
 */
@Serializable(with = FlexibleTimestampSerializer::class)
data class FlexibleTimestamp(val instant: Instant?)

object FlexibleTimestampSerializer : KSerializer<FlexibleTimestamp> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("FlexibleTimestamp", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): FlexibleTimestamp {
        if (decoder !is JsonDecoder) return FlexibleTimestamp(null)
        val element = decoder.decodeJsonElement()
        if (element is JsonNull) return FlexibleTimestamp(null)
        val primitive = element as? JsonPrimitive ?: return FlexibleTimestamp(null)
        // Numeric epoch-ms (or epoch-seconds for small values).
        primitive.longOrNull?.let { millis ->
            return FlexibleTimestamp(Instant.ofEpochMilli(if (millis < 1_000_000_000_000L) millis * 1000 else millis))
        }
        primitive.doubleOrNull?.let { d ->
            return FlexibleTimestamp(Instant.ofEpochMilli(d.toLong()))
        }
        val content = primitive.content
        if (content.isBlank() || content == "null") return FlexibleTimestamp(null)
        return FlexibleTimestamp(runCatching { Instant.parse(content) }.getOrNull())
    }

    override fun serialize(encoder: Encoder, value: FlexibleTimestamp) {
        val i = value.instant
        if (i == null) encoder.encodeString("") else encoder.encodeString(i.toString())
    }
}

// MARK: - Account

@Serializable
data class AutopilotAccountStatus(
    val isSignedIn: Boolean,
    val name: String? = null,
    val email: String? = null,
    val avatarURL: String? = null,
)

// MARK: - Pagination

@Serializable
data class Pagination(val nextCursor: String? = null, val hasMore: Boolean = false)

// MARK: - Automation / config (schema-driven)

@Serializable
data class SchemaEnvelope(val schema: JsonElement, val uiSchema: JsonElement? = null)

@Serializable
data class PreferencesValues(val values: JsonElement)

// MARK: - Repo setup

@Serializable
data class RepoSetupTemplate(
    val id: String,
    val name: String,
    val enabled: Boolean = true,
    val isDefault: Boolean = false,
    val mergeSettings: JsonElement,
    val rulesetConfig: JsonElement? = null,
)

@Serializable
data class RepoSetupTemplateList(val items: List<RepoSetupTemplate> = emptyList())

@Serializable
data class RepoSetupTemplateInput(
    val name: String,
    val enabled: Boolean,
    val isDefault: Boolean,
    val mergeSettings: JsonElement,
    val rulesetConfig: JsonElement? = null,
)

// MARK: - Shared repo picker

@Serializable
data class SecretsManagedRepo(
    val id: Long,
    val fullName: String,
    val name: String,
    val owner: String,
    @SerialName("private") val isPrivate: Boolean = false,
    val defaultBranch: String? = null,
    val secretsRepoId: String? = null,
    val installationId: Long,
    val environmentsCount: Int = 0,
    val filesCount: Int = 0,
    val isCurrent: Boolean = false,
) {
    val isManaged: Boolean get() = secretsRepoId != null
}

@Serializable
data class SecretsManagedRepoPage(
    val items: List<SecretsManagedRepo> = emptyList(),
    val pagination: Pagination = Pagination(),
)

@Serializable
data class AutopilotCloneRepoBody(val fullName: String)

@Serializable
data class AutopilotCloneRepoResult(val project: Project)

@Serializable
data class AutopilotInstallUrlResponse(val url: String)

// MARK: - Secrets

@Serializable
data class SecretsUserKey(
    val enrolled: Boolean = false,
    val publicKey: String? = null,
    val wrappedPrivateKey: String? = null,
    val wrapIv: String? = null,
    val algorithm: String? = null,
)

@Serializable
data class AutopilotSecretsEnrollment(val enrolled: Boolean)

@Serializable
data class SecretsEnvironment(
    val id: String,
    val name: String,
    val filesCount: Int? = null,
)

@Serializable
data class SecretsEnvironmentList(val items: List<SecretsEnvironment> = emptyList())

@Serializable
data class EnvironmentKeyBody(
    val wrapMode: String,
    val wrappedDek: String,
    val wrapIv: String? = null,
    val ephemeralPublicKey: String? = null,
)

@Serializable
data class CreateEnvironmentBody(val name: String, val ownerKey: EnvironmentKeyBody)

@Serializable
data class SecretsFileMeta(
    val id: String,
    val filename: String,
    val size: Int? = null,
    val encryptedByUserId: String? = null,
)

@Serializable
data class SecretsFileList(val items: List<SecretsFileMeta> = emptyList())

@Serializable
data class UpsertFileBody(
    val filename: String,
    val ciphertext: String,
    val iv: String,
    val size: Int? = null,
)

@Serializable
data class SecretsEnvironmentKey(
    val wrapMode: String,
    val wrappedDek: String,
    val wrapIv: String? = null,
    val ephemeralPublicKey: String? = null,
)

@Serializable
data class SecretsBundleFile(
    val filename: String,
    val ciphertext: String,
    val iv: String,
    val size: Int? = null,
)

@Serializable
data class SecretsBundle(
    val environmentKey: SecretsEnvironmentKey,
    val files: List<SecretsBundleFile> = emptyList(),
)

// MARK: - CI auto-update

@Serializable
enum class CIScanFrequency(val wire: String) {
    @SerialName("daily") DAILY("daily"),
    @SerialName("weekly") WEEKLY("weekly"),
    @SerialName("monthly") MONTHLY("monthly");

    val displayName: String
        get() = when (this) {
            DAILY -> "Daily"
            WEEKLY -> "Weekly"
            MONTHLY -> "Monthly"
        }
}

@Serializable
data class WatchedRepo(
    val id: String,
    val installationId: Long,
    val repositoryId: Long,
    val repositoryFullName: String,
    val owner: String? = null,
    val repo: String? = null,
    val lastScannedAt: FlexibleTimestamp? = null,
    val scheduleId: String? = null,
    @SerialName("scanFrequency") val scanFrequencyRaw: CIScanFrequency? = null,
    val createdAt: FlexibleTimestamp? = null,
    val updatedAt: FlexibleTimestamp? = null,
) {
    val fullName: String get() = repositoryFullName
    val scanFrequency: CIScanFrequency get() = scanFrequencyRaw ?: CIScanFrequency.WEEKLY
}

@Serializable
data class WatchedRepoPage(
    val repositories: List<WatchedRepo> = emptyList(),
    val nextCursor: String? = null,
    val hasMore: Boolean = false,
)

@Serializable
data class AddWatchedRepoBody(
    val installationId: Long,
    val repositoryId: Long,
    val repositoryFullName: String,
    val scanFrequency: CIScanFrequency,
)

@Serializable
data class CITriggerResponse(
    val success: Boolean = false,
    val prUrl: String? = null,
    val error: String? = null,
)

@Serializable
data class CIUpdateRunHistory(
    val id: String,
    val watchedRepositoryId: String? = null,
    val status: String = "",
    val workflowsScanned: Int? = null,
    val actionsFound: Int? = null,
    val outdatedActionsCount: Int? = null,
    val prUrl: String? = null,
    val prNumber: Int? = null,
    val errorMessage: String? = null,
    val startedAt: FlexibleTimestamp? = null,
    val completedAt: FlexibleTimestamp? = null,
) {
    val isSuccess: Boolean get() = status == "success"
}

@Serializable
data class CIPullRequest(
    val number: Int? = null,
    val title: String? = null,
    val state: String? = null,
    @SerialName("html_url") val htmlURL: String? = null,
    val merged: Boolean? = null,
    @SerialName("created_at") val createdAt: FlexibleTimestamp? = null,
) {
    val stableId: String get() = number?.toString() ?: (htmlURL ?: title ?: "pr")
    val isOpen: Boolean get() = (state ?: "open").lowercase() == "open"
}

// MARK: - Docs

@Serializable
data class DocsRepo(
    val id: String,
    val installationId: Long? = null,
    val repositoryId: Long? = null,
    val repositoryFullName: String,
    val owner: String? = null,
    val repo: String? = null,
    val lastIndexedAt: String? = null,
    val documentsCount: Int? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
) {
    val fullName: String get() = repositoryFullName
}

@Serializable
data class DocsRepoListResponse(
    val items: List<DocsRepo> = emptyList(),
    val pagination: Pagination? = null,
)

@Serializable
data class AddDocsRepoBody(
    val installationId: Long,
    val repositoryId: Long,
    val repositoryFullName: String,
)

@Serializable
data class DocsDocument(
    val docId: String,
    val title: String? = null,
    val embeddingStatus: String? = null,
    val updatedAt: String? = null,
)

@Serializable
data class DocsDocumentList(
    val items: List<DocsDocument> = emptyList(),
    val pagination: Pagination? = null,
)

@Serializable
data class DocsDocumentVersion(
    val id: String? = null,
    val documentId: String? = null,
    val version: Int = 0,
    val content: String? = null,
    val contentHash: String? = null,
    val embeddingStatus: String? = null,
    val embeddingError: String? = null,
    val createdAt: String? = null,
    val embeddedAt: String? = null,
)

@Serializable
data class DocsDocumentDetail(
    val document: Document,
    val currentVersion: DocsDocumentVersion? = null,
) {
    @Serializable
    data class Document(
        val id: String? = null,
        val docsRepositoryId: String? = null,
        val docId: String,
        val originalLink: String? = null,
        val currentVersionId: String? = null,
        val currentVersion: Int? = null,
        val createdAt: String? = null,
        val updatedAt: String? = null,
    )
}

@Serializable
data class DocsUploadResult(
    val jobId: String? = null,
    val accepted: Int? = null,
    val skipped: Int? = null,
    val total: Int? = null,
)

@Serializable
data class DocsUploadToken(
    val id: String? = null,
    val plaintext: String? = null,
    val tokenPrefix: String? = null,
) {
    val token: String? get() = plaintext
}

@Serializable
data class DocsGithubSecretResult(
    val secretName: String,
    val repositoryFullName: String,
)

// MARK: - Release

@Serializable
data class ReleaseRepo(
    val id: String,
    val installationId: Long? = null,
    val repositoryId: Long? = null,
    val repositoryFullName: String,
    val owner: String? = null,
    val repo: String? = null,
    val lastScannedAt: String? = null,
    val latestReleaseTag: String? = null,
    val latestReleaseAt: String? = null,
    val versionsListVisibility: String? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
) {
    val fullName: String get() = repositoryFullName
}

@Serializable
data class ReleaseRepoListResponse(
    val items: List<ReleaseRepo> = emptyList(),
    val pagination: Pagination? = null,
)

@Serializable
data class AddReleaseRepoBody(
    val installationId: Long,
    val repositoryId: Long,
    val repositoryFullName: String,
)

@Serializable
data class MobileReleaseWorkflowInput(
    val name: String,
    val type: String,
    val description: String? = null,
    val required: Boolean = false,
    val defaultString: String? = null,
    val defaultBool: Boolean? = null,
    val options: List<String>? = null,
)

@Serializable
data class MobileReleaseWorkflow(
    val id: String,
    val workflowPath: String,
    val workflowName: String? = null,
    val isSelected: Boolean = false,
    val isReleaseWorkflow: Boolean? = null,
    val hasWorkflowDispatch: Boolean = false,
    val inputs: List<MobileReleaseWorkflowInput>? = null,
) {
    val displayName: String
        get() = workflowName?.takeIf { it.isNotEmpty() }
            ?: workflowPath.substringAfterLast('/')
}

@Serializable
data class ReleaseDispatchRequest(
    val workflowId: String,
    val branch: String,
    val inputs: Map<String, String> = emptyMap(),
)

@Serializable
data class ReleaseDispatchResult(
    val success: Boolean? = null,
    val dispatchId: String? = null,
    val workflowRunUrl: String? = null,
    val error: String? = null,
)

@Serializable
data class ReleaseGithubSecretResult(
    val secretName: String,
    val repositoryFullName: String,
)

// MARK: - Project context-menu results

/**
 * Per-project autopilot state powering the mobile context menu. Mirrors the
 * desktop's hasSecrets / hasDocs / hasRelease checks so the phone picks the
 * same menu items (Download vs Set Up, etc.).
 */
@Serializable
data class AutopilotProjectStatus(
    val gitHubRepo: String? = null,
    val hasSecrets: Boolean = false,
    val hasDocs: Boolean = false,
    val hasRelease: Boolean = false,
)

/** Result of `projectCreatePullRequest`: the URL of the opened pull request. */
@Serializable
data class AutopilotPullRequestResult(val url: String)

/** Result of `projectSecretsWrite`: files written and any skipped conflicts. */
@Serializable
data class AutopilotProjectSecretsDownloadResult(
    val written: List<String> = emptyList(),
    val conflicts: List<String> = emptyList(),
)

// MARK: - Global search

/** One thread match from the desktop's on-device index. */
@Serializable
data class SearchHit(
    val sessionID: String,
    @Serializable(with = UuidSerializer::class) val projectID: UUID,
    val title: String,
    val snippet: String,
    @Serializable(with = SwiftDateSerializer::class) val updatedAt: Instant,
    val score: Float = 0f,
)

/** One published-docs match from the rxlab docs service. */
@Serializable
data class DocsSearchHit(
    val documentId: String? = null,
    val docId: String,
    val docsRepositoryId: String? = null,
    val repositoryFullName: String? = null,
    val version: Int? = null,
    val similarity: Double? = null,
    val snippet: String? = null,
    val originalLink: String? = null,
) {
    val stableId: String get() = documentId ?: "${repositoryFullName ?: ""}:$docId"
}

/** Combined search results for one query: thread hits + doc hits. */
@Serializable
data class AutopilotSearchResult(
    val query: String,
    val projectIDs: List<@Serializable(with = UuidSerializer::class) UUID> = emptyList(),
    val threadHits: List<SearchHit> = emptyList(),
    val docHits: List<DocsSearchHit> = emptyList(),
)
