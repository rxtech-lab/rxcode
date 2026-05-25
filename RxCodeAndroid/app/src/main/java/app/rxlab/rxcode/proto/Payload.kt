package app.rxlab.rxcode.proto

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.descriptors.element
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant
import java.util.UUID

/**
 * Plaintext payloads exchanged between paired devices. Wire shape is
 * `{ "type": "<snake_case>", "data": {...} }`; unknown types decode to
 * [Payload.Unknown] so a newer desktop can talk to an older client without
 * dropping the whole envelope.
 *
 * Only the subset of payloads Phase 1 actually consumes carries a strongly
 * typed body; everything else falls through to [Payload.Unknown] until later
 * phases extend it.
 */
@Serializable(with = PayloadSerializer::class)
sealed class Payload {
    abstract val type: String

    data class PairRequest(val data: PairRequestPayload) : Payload() {
        override val type = "pair_request"
    }
    data class PairAck(val data: PairAckPayload) : Payload() {
        override val type = "pair_ack"
    }
    data class Unpair(val data: UnpairPayload) : Payload() {
        override val type = "unpair"
    }
    data class RequestSnapshot(val data: RequestSnapshotPayload) : Payload() {
        override val type = "request_snapshot"
    }
    data class Snapshot(val data: SnapshotPayload) : Payload() {
        override val type = "snapshot"
    }
    data class SessionUpdate(val data: SessionUpdatePayload) : Payload() {
        override val type = "session_update"
    }
    data class SubscribeSession(val data: SubscribeSessionPayload) : Payload() {
        override val type = "subscribe_session"
    }
    data class UserMessage(val data: UserMessagePayload) : Payload() {
        override val type = "user_message"
    }
    data class CancelStream(val data: CancelStreamPayload) : Payload() {
        override val type = "cancel_stream"
    }
    data class NewSessionRequest(val data: NewSessionRequestPayload) : Payload() {
        override val type = "new_session_request"
    }
    data class ThreadActionRequest(val data: ThreadActionRequestPayload) : Payload() {
        override val type = "thread_action_request"
    }
    data class LoadMoreMessages(val data: LoadMoreMessagesRequestPayload) : Payload() {
        override val type = "load_more_messages"
    }
    data class MoreMessages(val data: MoreMessagesPayload) : Payload() {
        override val type = "more_messages"
    }
    data class PermissionRequest(val data: PermissionRequestPayload) : Payload() {
        override val type = "permission_request"
    }
    data class PermissionResponse(val data: PermissionResponsePayload) : Payload() {
        override val type = "permission_response"
    }
    data class QuestionQueue(val data: QuestionQueuePayload) : Payload() {
        override val type = "question_queue"
    }
    data class QuestionAnswer(val data: QuestionAnswerPayload) : Payload() {
        override val type = "question_answer"
    }
    data class PlanDecision(val data: PlanDecisionPayload) : Payload() {
        override val type = "plan_decision"
    }
    data class BranchOpRequest(val data: BranchOpRequestPayload) : Payload() {
        override val type = "branch_op_request"
    }
    data class BranchOpResult(val data: BranchOpResultPayload) : Payload() {
        override val type = "branch_op_result"
    }
    data class RunProfileMutationRequest(val data: RunProfileMutationRequestPayload) : Payload() {
        override val type = "run_profile_mutation_request"
    }
    data class RunProfileResult(val data: RunProfileResultPayload) : Payload() {
        override val type = "run_profile_result"
    }
    data class RunProfileRunRequest(val data: RunProfileRunRequestPayload) : Payload() {
        override val type = "run_profile_run_request"
    }
    data class RunProfileStopRequest(val data: RunProfileStopRequestPayload) : Payload() {
        override val type = "run_profile_stop_request"
    }
    data class RunTaskUpdate(val data: RunTaskUpdatePayload) : Payload() {
        override val type = "run_task_update"
    }
    data class ThreadChangesRequest(val data: ThreadChangesRequestPayload) : Payload() {
        override val type = "thread_changes_request"
    }
    data class ThreadChangesResult(val data: ThreadChangesResultPayload) : Payload() {
        override val type = "thread_changes_result"
    }
    data class Ping(val data: PingPayload) : Payload() {
        override val type = "ping"
    }
    data class Pong(val data: PongPayload) : Payload() {
        override val type = "pong"
    }
    data class Unknown(override val type: String, val raw: JsonObject? = null) : Payload()
}

// MARK: - Wire structs

@Serializable
data class PairRequestPayload(
    val mobilePubkeyHex: String,
    val displayName: String,
    val platform: String,
    val appVersion: String,
    val apnsEnvironment: String? = null,
)

@Serializable
data class PairAckPayload(
    val accepted: Boolean,
    val desktopName: String,
    val reason: String? = null,
)

@Serializable
data class UnpairPayload(val reason: String? = null)

@Serializable
data class RequestSnapshotPayload(val activeSessionID: String? = null)

@Serializable
data class SnapshotPayload(
    val projects: List<Project> = emptyList(),
    val sessions: List<SessionSummary> = emptyList(),
    val branchBriefings: List<MobileBranchBriefing>? = null,
    val threadSummaries: List<MobileThreadSummary>? = null,
    val projectBranches: List<ProjectBranchInfo>? = null,
    val activeSessionID: String? = null,
    val activeSessionMessages: List<ChatMessage>? = null,
    val activeSessionHasMore: Boolean? = null,
    val runProfiles: List<MobileProjectRunProfiles>? = null,
    val runTasks: List<MobileRunTaskSnapshot>? = null,
    val webProxy: MobileWebProxyInfo? = null,
)

@Serializable
data class SubscribeSessionPayload(val sessionID: String?)

@Serializable
data class UserMessagePayload(
    @Serializable(with = UuidSerializer::class) val clientMessageID: UUID = UUID.randomUUID(),
    val sessionID: String,
    val text: String,
)

@Serializable
data class CancelStreamPayload(val sessionID: String)

@Serializable
data class NewSessionRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    @Serializable(with = UuidSerializer::class) val projectID: UUID,
    val initialText: String? = null,
    val selectedAgentProvider: AgentProvider? = null,
    val selectedModel: String? = null,
    val permissionMode: PermissionMode? = null,
    val planMode: Boolean? = null,
)

@Serializable
data class ThreadActionRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val sessionID: String,
    val action: ThreadAction,
    val newTitle: String? = null,
) {
    @Serializable
    enum class ThreadAction {
        @SerialName("rename") RENAME,
        @SerialName("archive") ARCHIVE,
        @SerialName("unarchive") UNARCHIVE,
        @SerialName("delete") DELETE,
    }
}

@Serializable
data class LoadMoreMessagesRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val sessionID: String,
    @Serializable(with = UuidSerializer::class) val beforeMessageID: UUID,
    val limit: Int,
)

@Serializable
data class MoreMessagesPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val sessionID: String,
    val messages: List<ChatMessage>,
    val hasMore: Boolean,
)

@Serializable
data class SessionUpdatePayload(
    val sessionID: String,
    val kind: Kind,
    val message: ChatMessage? = null,
    val isStreaming: Boolean? = null,
    val isThinking: Boolean? = null,
    val summary: SessionSummary? = null,
    val previousSessionID: String? = null,
) {
    @Serializable
    enum class Kind {
        @SerialName("messageAppended") MESSAGE_APPENDED,
        @SerialName("messageUpdated") MESSAGE_UPDATED,
        @SerialName("streamingStarted") STREAMING_STARTED,
        @SerialName("streamingFinished") STREAMING_FINISHED,
        @SerialName("statusChanged") STATUS_CHANGED,
    }
}

@Serializable
data class PermissionRequestPayload(
    val requestID: String,
    val toolName: String,
    val toolInputJSON: String,
    val sessionID: String? = null,
)

@Serializable
data class PermissionResponsePayload(
    val requestID: String,
    val allow: Boolean,
    val denyReason: String? = null,
)

@Serializable
data class PendingQuestionPayload(
    val toolUseID: String,
    val sessionID: String,
    val toolInputJSON: String,
)

@Serializable
data class QuestionQueuePayload(val questions: List<PendingQuestionPayload>)

@Serializable
data class QuestionAnswerEntry(
    val questionIndex: Int,
    val values: List<String>,
    val multiSelect: Boolean,
)

@Serializable
data class QuestionAnswerPayload(
    val toolUseID: String,
    val answers: List<QuestionAnswerEntry>,
)

@Serializable
data class PlanDecisionPayload(
    val toolUseID: String,
    val sessionID: String,
    val action: Action,
    val reason: String? = null,
) {
    @Serializable
    enum class Action {
        @SerialName("acceptAsk") ACCEPT_ASK,
        @SerialName("acceptWithEdits") ACCEPT_WITH_EDITS,
        @SerialName("acceptAutoApprove") ACCEPT_AUTO_APPROVE,
        @SerialName("reject") REJECT,
        @SerialName("rejectWithFeedback") REJECT_WITH_FEEDBACK,
    }
}

/**
 * Mobile-initiated request to switch to / create a branch (with worktree) or
 * initialize a git repo in the project root. Desktop replies with
 * [BranchOpResultPayload]; on success it broadcasts a fresh snapshot so we
 * pick up the new branch metadata.
 */
@Serializable
data class BranchOpRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    @Serializable(with = UuidSerializer::class) val projectID: UUID,
    val operation: Operation,
    val branch: String,
) {
    @Serializable
    enum class Operation {
        @SerialName("switchExisting") SWITCH_EXISTING,
        @SerialName("createNew") CREATE_NEW,
        @SerialName("initGit") INIT_GIT,
    }
}

@Serializable
data class BranchOpResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    @Serializable(with = UuidSerializer::class) val projectID: UUID,
    val operation: BranchOpRequestPayload.Operation,
    val branch: String,
    val ok: Boolean,
    val errorMessage: String? = null,
)

/**
 * Mobile → desktop request to upsert or delete a [RunProfile]. The desktop
 * replies with [RunProfileResultPayload]; on success it also broadcasts a
 * fresh snapshot so all paired devices converge on the new profile list.
 */
@Serializable
data class RunProfileMutationRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    @Serializable(with = UuidSerializer::class) val projectID: UUID,
    val operation: Operation,
    val profile: RunProfile? = null,
    @Serializable(with = UuidSerializer::class) val profileID: UUID? = null,
) {
    @Serializable
    enum class Operation {
        @SerialName("upsert") UPSERT,
        @SerialName("delete") DELETE,
    }
}

@Serializable
data class RunProfileRunRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    @Serializable(with = UuidSerializer::class) val projectID: UUID,
    @Serializable(with = UuidSerializer::class) val profileID: UUID,
)

@Serializable
data class RunProfileStopRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    @Serializable(with = UuidSerializer::class) val taskID: UUID? = null,
    @Serializable(with = UuidSerializer::class) val projectID: UUID? = null,
    @Serializable(with = UuidSerializer::class) val profileID: UUID? = null,
)

@Serializable
data class RunProfileResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    @Serializable(with = UuidSerializer::class) val projectID: UUID,
    val ok: Boolean,
    val errorMessage: String? = null,
    val profiles: List<RunProfile>? = null,
    val task: MobileRunTaskSnapshot? = null,
)

@Serializable
data class RunTaskUpdatePayload(val task: MobileRunTaskSnapshot)

/**
 * Mobile → desktop request to fetch the list of file changes for a thread.
 * The desktop replies with [ThreadChangesResultPayload]. Used by the
 * "View Changes" sheet (mirrors iOS `ThreadChangesSheet`).
 */
@Serializable
data class ThreadChangesRequestPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID = UUID.randomUUID(),
    val sessionID: String,
)

@Serializable
data class SyncEditHunk(
    val oldString: String,
    val newString: String,
)

@Serializable
data class SyncFileEdit(
    val path: String,
    val name: String,
    val containsWrite: Boolean,
    val hunks: List<SyncEditHunk> = emptyList(),
    val fullFileDiff: String? = null,
    val originalContent: String? = null,
    val modifiedContent: String? = null,
)

@Serializable
enum class SyncGitChangeKind {
    @SerialName("staged") STAGED,
    @SerialName("unstaged") UNSTAGED,
    @SerialName("untracked") UNTRACKED,
}

@Serializable
data class SyncGitChange(
    val displayPath: String,
    val statusChar: String,
    val kind: SyncGitChangeKind,
    val unifiedDiff: String,
    val truncated: Boolean,
)

@Serializable
data class ThreadChangesResultPayload(
    @Serializable(with = UuidSerializer::class) val clientRequestID: UUID,
    val sessionID: String,
    val ok: Boolean,
    val errorMessage: String? = null,
    val turnEdits: List<SyncFileEdit> = emptyList(),
    val uncommitted: List<SyncGitChange> = emptyList(),
)

@Serializable
data class PingPayload(
    @Serializable(with = SwiftDateSerializer::class) val t: Instant = Instant.now(),
)

@Serializable
data class PongPayload(
    @Serializable(with = SwiftDateSerializer::class) val t: Instant = Instant.now(),
)

// MARK: - Polymorphic serializer

/**
 * Encodes/decodes Swift's `{ "type": ..., "data": ... }` tag-then-payload
 * shape. Unknown `type` values become [Payload.Unknown] so newer payloads
 * don't kill the connection.
 */
object PayloadSerializer : KSerializer<Payload> {
    override val descriptor: SerialDescriptor = buildClassSerialDescriptor("Payload") {
        element<String>("type")
        element<JsonObject>("data")
    }

    override fun deserialize(decoder: Decoder): Payload {
        val input = decoder as? JsonDecoder
            ?: error("Payload requires kotlinx.serialization.json.JsonDecoder")
        val obj = input.decodeJsonElement().jsonObject
        val type = obj["type"]?.jsonPrimitive?.contentOrNullSafe()
            ?: return Payload.Unknown("", obj)
        val data = obj["data"] as? JsonObject ?: JsonObject(emptyMap())
        val json = input.json
        return when (type) {
            "pair_request" -> Payload.PairRequest(json.decodeFromJsonElement(PairRequestPayload.serializer(), data))
            "pair_ack" -> Payload.PairAck(json.decodeFromJsonElement(PairAckPayload.serializer(), data))
            "unpair" -> Payload.Unpair(json.decodeFromJsonElement(UnpairPayload.serializer(), data))
            "request_snapshot" -> Payload.RequestSnapshot(json.decodeFromJsonElement(RequestSnapshotPayload.serializer(), data))
            "snapshot" -> Payload.Snapshot(json.decodeFromJsonElement(SnapshotPayload.serializer(), data))
            "session_update" -> Payload.SessionUpdate(json.decodeFromJsonElement(SessionUpdatePayload.serializer(), data))
            "subscribe_session" -> Payload.SubscribeSession(json.decodeFromJsonElement(SubscribeSessionPayload.serializer(), data))
            "user_message" -> Payload.UserMessage(json.decodeFromJsonElement(UserMessagePayload.serializer(), data))
            "cancel_stream" -> Payload.CancelStream(json.decodeFromJsonElement(CancelStreamPayload.serializer(), data))
            "new_session_request" -> Payload.NewSessionRequest(json.decodeFromJsonElement(NewSessionRequestPayload.serializer(), data))
            "thread_action_request" -> Payload.ThreadActionRequest(json.decodeFromJsonElement(ThreadActionRequestPayload.serializer(), data))
            "load_more_messages" -> Payload.LoadMoreMessages(json.decodeFromJsonElement(LoadMoreMessagesRequestPayload.serializer(), data))
            "more_messages" -> Payload.MoreMessages(json.decodeFromJsonElement(MoreMessagesPayload.serializer(), data))
            "permission_request" -> Payload.PermissionRequest(json.decodeFromJsonElement(PermissionRequestPayload.serializer(), data))
            "permission_response" -> Payload.PermissionResponse(json.decodeFromJsonElement(PermissionResponsePayload.serializer(), data))
            "question_queue" -> Payload.QuestionQueue(json.decodeFromJsonElement(QuestionQueuePayload.serializer(), data))
            "question_answer" -> Payload.QuestionAnswer(json.decodeFromJsonElement(QuestionAnswerPayload.serializer(), data))
            "plan_decision" -> Payload.PlanDecision(json.decodeFromJsonElement(PlanDecisionPayload.serializer(), data))
            "branch_op_request" -> Payload.BranchOpRequest(json.decodeFromJsonElement(BranchOpRequestPayload.serializer(), data))
            "branch_op_result" -> Payload.BranchOpResult(json.decodeFromJsonElement(BranchOpResultPayload.serializer(), data))
            "run_profile_mutation_request" -> Payload.RunProfileMutationRequest(json.decodeFromJsonElement(RunProfileMutationRequestPayload.serializer(), data))
            "run_profile_result" -> Payload.RunProfileResult(json.decodeFromJsonElement(RunProfileResultPayload.serializer(), data))
            "run_profile_run_request" -> Payload.RunProfileRunRequest(json.decodeFromJsonElement(RunProfileRunRequestPayload.serializer(), data))
            "run_profile_stop_request" -> Payload.RunProfileStopRequest(json.decodeFromJsonElement(RunProfileStopRequestPayload.serializer(), data))
            "run_task_update" -> Payload.RunTaskUpdate(json.decodeFromJsonElement(RunTaskUpdatePayload.serializer(), data))
            "thread_changes_request" -> Payload.ThreadChangesRequest(json.decodeFromJsonElement(ThreadChangesRequestPayload.serializer(), data))
            "thread_changes_result" -> Payload.ThreadChangesResult(json.decodeFromJsonElement(ThreadChangesResultPayload.serializer(), data))
            "ping" -> Payload.Ping(json.decodeFromJsonElement(PingPayload.serializer(), data))
            "pong" -> Payload.Pong(json.decodeFromJsonElement(PongPayload.serializer(), data))
            else -> Payload.Unknown(type, data)
        }
    }

    override fun serialize(encoder: Encoder, value: Payload) {
        val output = encoder as? JsonEncoder
            ?: error("Payload requires kotlinx.serialization.json.JsonEncoder")
        val json = output.json
        val (typeStr, dataElement) = when (value) {
            is Payload.PairRequest -> value.type to json.encodeToJsonElement(PairRequestPayload.serializer(), value.data)
            is Payload.PairAck -> value.type to json.encodeToJsonElement(PairAckPayload.serializer(), value.data)
            is Payload.Unpair -> value.type to json.encodeToJsonElement(UnpairPayload.serializer(), value.data)
            is Payload.RequestSnapshot -> value.type to json.encodeToJsonElement(RequestSnapshotPayload.serializer(), value.data)
            is Payload.Snapshot -> value.type to json.encodeToJsonElement(SnapshotPayload.serializer(), value.data)
            is Payload.SessionUpdate -> value.type to json.encodeToJsonElement(SessionUpdatePayload.serializer(), value.data)
            is Payload.SubscribeSession -> value.type to json.encodeToJsonElement(SubscribeSessionPayload.serializer(), value.data)
            is Payload.UserMessage -> value.type to json.encodeToJsonElement(UserMessagePayload.serializer(), value.data)
            is Payload.CancelStream -> value.type to json.encodeToJsonElement(CancelStreamPayload.serializer(), value.data)
            is Payload.NewSessionRequest -> value.type to json.encodeToJsonElement(NewSessionRequestPayload.serializer(), value.data)
            is Payload.ThreadActionRequest -> value.type to json.encodeToJsonElement(ThreadActionRequestPayload.serializer(), value.data)
            is Payload.LoadMoreMessages -> value.type to json.encodeToJsonElement(LoadMoreMessagesRequestPayload.serializer(), value.data)
            is Payload.MoreMessages -> value.type to json.encodeToJsonElement(MoreMessagesPayload.serializer(), value.data)
            is Payload.PermissionRequest -> value.type to json.encodeToJsonElement(PermissionRequestPayload.serializer(), value.data)
            is Payload.PermissionResponse -> value.type to json.encodeToJsonElement(PermissionResponsePayload.serializer(), value.data)
            is Payload.QuestionQueue -> value.type to json.encodeToJsonElement(QuestionQueuePayload.serializer(), value.data)
            is Payload.QuestionAnswer -> value.type to json.encodeToJsonElement(QuestionAnswerPayload.serializer(), value.data)
            is Payload.PlanDecision -> value.type to json.encodeToJsonElement(PlanDecisionPayload.serializer(), value.data)
            is Payload.BranchOpRequest -> value.type to json.encodeToJsonElement(BranchOpRequestPayload.serializer(), value.data)
            is Payload.BranchOpResult -> value.type to json.encodeToJsonElement(BranchOpResultPayload.serializer(), value.data)
            is Payload.RunProfileMutationRequest -> value.type to json.encodeToJsonElement(RunProfileMutationRequestPayload.serializer(), value.data)
            is Payload.RunProfileResult -> value.type to json.encodeToJsonElement(RunProfileResultPayload.serializer(), value.data)
            is Payload.RunProfileRunRequest -> value.type to json.encodeToJsonElement(RunProfileRunRequestPayload.serializer(), value.data)
            is Payload.RunProfileStopRequest -> value.type to json.encodeToJsonElement(RunProfileStopRequestPayload.serializer(), value.data)
            is Payload.RunTaskUpdate -> value.type to json.encodeToJsonElement(RunTaskUpdatePayload.serializer(), value.data)
            is Payload.ThreadChangesRequest -> value.type to json.encodeToJsonElement(ThreadChangesRequestPayload.serializer(), value.data)
            is Payload.ThreadChangesResult -> value.type to json.encodeToJsonElement(ThreadChangesResultPayload.serializer(), value.data)
            is Payload.Ping -> value.type to json.encodeToJsonElement(PingPayload.serializer(), value.data)
            is Payload.Pong -> value.type to json.encodeToJsonElement(PongPayload.serializer(), value.data)
            is Payload.Unknown -> value.type to (value.raw ?: JsonObject(emptyMap()))
        }
        val wire = buildJsonObject {
            put("type", JsonPrimitive(typeStr))
            put("data", dataElement)
        }
        output.encodeJsonElement(wire)
    }
}

private fun JsonPrimitive.contentOrNullSafe(): String? =
    if (isString) content else content.takeIf { it.isNotEmpty() && it != "null" }
