package app.rxlab.rxcode.proto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

/**
 * Domain types mirroring the Swift `RxCodeCore` and `RxCodeSync` models that
 * Phase 1 of the Android client needs. Trimmed to fields the UI actually reads;
 * unknown JSON keys are tolerated by [RxJson] so newer desktops can extend the
 * wire format without breaking us.
 */

@Serializable
data class Project(
    @Serializable(with = UuidSerializer::class) val id: UUID,
    val name: String,
    val path: String,
    val gitHubRepo: String? = null,
    val lastSessionId: String? = null,
)

@Serializable
data class SessionSummary(
    val id: String,
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val title: String,
    @Serializable(with = SwiftDateSerializer::class) val updatedAt: Instant,
    val isPinned: Boolean = false,
    val isArchived: Boolean = false,
    val isStreaming: Boolean = false,
    val attention: SessionAttentionKind? = null,
    val hasUncheckedCompletion: Boolean = false,
    val queuedMessages: List<QueuedUserMessage> = emptyList(),
    val todos: List<TodoItem>? = null,
    /** Id of the thread this was spawned from (e.g. a [Code Review] thread). */
    val parentThreadId: String? = null,
    /** Short label chip (e.g. "Code Review"). Null for ordinary threads. */
    val threadLabel: String? = null,
)

@Serializable
enum class SessionAttentionKind {
    @SerialName("permission") PERMISSION,
    @SerialName("question") QUESTION,
}

@Serializable
data class QueuedUserMessage(
    @Serializable(with = UuidSerializer::class) val id: UUID,
    val text: String,
)

@Serializable
enum class Role {
    @SerialName("user") USER,
    @SerialName("assistant") ASSISTANT,
}

@Serializable
data class ToolCall(
    val id: String,
    val name: String,
    val input: kotlinx.serialization.json.JsonObject =
        kotlinx.serialization.json.JsonObject(emptyMap()),
    val result: String? = null,
    val isError: Boolean = false,
)

@Serializable
data class MessageBlock(
    val id: String,
    val text: String? = null,
    val toolCall: ToolCall? = null,
)

@Serializable
data class ChatMessage(
    @Serializable(with = UuidSerializer::class) val id: UUID,
    val role: Role,
    val blocks: List<MessageBlock> = emptyList(),
    val isStreaming: Boolean = false,
    val isResponseComplete: Boolean = false,
    @Serializable(with = SwiftDateSerializer::class) val timestamp: Instant,
    val duration: Double? = null,
    val isError: Boolean = false,
    val isCompactBoundary: Boolean = false,
) {
    val textContent: String
        get() = blocks.mapNotNull { it.text }.joinToString("\n\n")

    val toolCalls: List<ToolCall> get() = blocks.mapNotNull { it.toolCall }
}

@Serializable
enum class AgentProvider {
    @SerialName("claudeCode") CLAUDE_CODE,
    @SerialName("codex") CODEX,
    @SerialName("acp") ACP,
}

@Serializable
enum class PermissionMode {
    @SerialName("default") DEFAULT,
    @SerialName("acceptEdits") ACCEPT_EDITS,
    @SerialName("bypassPermissions") BYPASS_PERMISSIONS,
    @SerialName("plan") PLAN,
}

/**
 * Per-branch briefing produced by the desktop after threads complete.
 * Mirrors Swift `MobileBranchBriefing`.
 */
@Serializable
data class MobileBranchBriefing(
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val branch: String,
    val briefing: String,
    @Serializable(with = SwiftDateSerializer::class) val updatedAt: Instant,
) {
    val id: String get() = "$projectId::$branch"
}

/**
 * Per-thread summary shown inside a briefing card. Mirrors
 * Swift `MobileThreadSummary`.
 */
@Serializable
data class MobileThreadSummary(
    val sessionId: String,
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val branch: String,
    val title: String,
    val summary: String,
    @Serializable(with = SwiftDateSerializer::class) val updatedAt: Instant,
) {
    val id: String get() = sessionId
}

/**
 * Current git branch and available branches for a project, sent by the
 * desktop so mobile can populate the branch picker in the new-thread sheet
 * and the briefing filter.
 */
@Serializable
data class ProjectBranchInfo(
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val currentBranch: String,
    val availableBranches: List<String>? = null,
)

/**
 * Per-repo CI / pull-request status mirrored from the desktop, used to gate the
 * "Create Pull Request" menu item (only offered when a branch has no PR yet).
 * Mirrors a subset of Swift `ProjectCIStatus`; unknown keys (workflows, failing,
 * etc.) are ignored by [RxJson].
 */
@Serializable
data class ProjectCIStatus(
    val owner: String = "",
    val repo: String = "",
    val branch: String? = null,
    val found: Boolean = false,
    val prNumber: Int? = null,
    val prState: String? = null,
    val prUrl: String? = null,
)

/**
 * One project's CI status, keyed by project id. Mirrors Swift
 * `MobileProjectCIStatus` from the snapshot payload.
 */
@Serializable
data class MobileProjectCIStatus(
    @Serializable(with = UuidSerializer::class) val projectId: UUID,
    val status: ProjectCIStatus,
)
