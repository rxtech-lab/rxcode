package app.rxlab.rxcode.state

import app.rxlab.rxcode.proto.ChatMessage
import app.rxlab.rxcode.proto.MobileBranchBriefing
import app.rxlab.rxcode.proto.MobileRunTaskSnapshot
import app.rxlab.rxcode.proto.MobileThreadSummary
import app.rxlab.rxcode.proto.MobileWebProxyInfo
import app.rxlab.rxcode.proto.PendingQuestionPayload
import app.rxlab.rxcode.proto.PermissionRequestPayload
import app.rxlab.rxcode.proto.Project
import app.rxlab.rxcode.proto.ProjectBranchInfo
import app.rxlab.rxcode.proto.RunProfile
import app.rxlab.rxcode.proto.SessionSummary
import app.rxlab.rxcode.proto.ThreadChangesResultPayload
import app.rxlab.rxcode.relay.RelayClient
import app.rxlab.rxcode.store.PairedDesktop
import java.util.UUID

/**
 * Immutable snapshot of every piece of state Phase 1 of the UI cares about.
 * Mutated by [MobileAppState] via `update { copy(...) }` so Compose collectors
 * see one atomic change per inbound event.
 */
data class MobileState(
    val pairedDesktops: List<PairedDesktop> = emptyList(),
    val activeDesktopPubkey: String = "",
    val relayUrl: String = "",
    val connectionState: RelayClient.ConnectionState = RelayClient.ConnectionState.DISCONNECTED,
    val pairing: PairingStatus = PairingStatus.Idle,

    val projects: List<Project> = emptyList(),
    val sessions: List<SessionSummary> = emptyList(),
    val activeSessionID: String? = null,
    val messagesBySession: Map<String, List<ChatMessage>> = emptyMap(),
    val sessionsWithMoreMessages: Set<String> = emptySet(),
    val loadingMoreSessions: Set<String> = emptySet(),
    val loadingThreadMessageSessions: Set<String> = emptySet(),
    val thinkingSessions: Set<String> = emptySet(),
    val sessionIDRedirects: Map<String, String> = emptyMap(),

    /** Per-branch briefings keyed by `"<projectId>::<branch>"`. */
    val branchBriefings: List<MobileBranchBriefing> = emptyList(),
    /** Per-thread summary cards shown inside a briefing detail. */
    val threadSummaries: List<MobileThreadSummary> = emptyList(),
    /** Current + available branches per project, indexed by project id. */
    val projectBranches: Map<UUID, ProjectBranchInfo> = emptyMap(),

    val pendingPermission: PermissionRequestPayload? = null,
    val pendingQuestions: List<PendingQuestionPayload> = emptyList(),

    /** Project ids with an in-flight branch op (init / switch / create). */
    val pendingBranchOps: Set<UUID> = emptySet(),

    /** Run profiles synced from the desktop, indexed by project id. */
    val runProfilesByProject: Map<UUID, List<RunProfile>> = emptyMap(),
    /** All current/recent run tasks broadcast by the desktop. */
    val runTasks: List<MobileRunTaskSnapshot> = emptyList(),
    /**
     * HTTP proxy exposed by the desktop so the mobile in-app browser can reach
     * localhost dev servers running on the Mac. `null` when the desktop predates
     * proxy support or hasn't published its endpoint yet.
     */
    val desktopWebProxy: MobileWebProxyInfo? = null,

    /**
     * Latest thread-changes result returned by the desktop. Keyed by
     * `sessionID` on consumption so a stale result from a previously opened
     * thread is treated as "not yet loaded" by [ThreadChangesSheet].
     */
    val threadChanges: ThreadChangesResultPayload? = null,
    val isLoadingThreadChanges: Boolean = false,

    val hasReceivedInitialSnapshot: Boolean = false,
    val lastError: String? = null,
) {
    val isPaired: Boolean get() = activeDesktopPubkey.isNotEmpty()

    val activeDesktop: PairedDesktop?
        get() = pairedDesktops.firstOrNull { it.pubkeyHex == activeDesktopPubkey }
}

sealed interface PairingStatus {
    object Idle : PairingStatus
    object InProgress : PairingStatus
    data class Failed(val message: String) : PairingStatus
}

/** Maps a possibly-stale session id through the optimistic-redirect chain. */
fun MobileState.resolveSessionId(id: String): String {
    var cursor = id
    val seen = mutableSetOf<String>()
    while (true) {
        val next = sessionIDRedirects[cursor] ?: return cursor
        if (!seen.add(cursor)) return cursor // cycle guard
        cursor = next
    }
}

/** Convenience: messages for the active session, after redirect resolution. */
fun MobileState.activeMessages(): List<ChatMessage> {
    val id = activeSessionID ?: return emptyList()
    return messagesBySession[resolveSessionId(id)].orEmpty()
}

/** Optimistic placeholder id for a thread we just asked the desktop to create. */
fun draftSessionId(projectId: UUID): String = "draft-new:$projectId:${UUID.randomUUID()}"

fun isDraftSessionId(id: String): Boolean = id.startsWith("draft-new:")

/** Run profiles for [projectId], sorted alphabetically. */
fun MobileState.runProfilesFor(projectId: UUID): List<RunProfile> =
    runProfilesByProject[projectId].orEmpty().sortedBy { it.name.lowercase() }

/** Active + recent run tasks for [projectId], newest first. */
fun MobileState.runTasksFor(projectId: UUID): List<MobileRunTaskSnapshot> =
    runTasks.filter { it.projectId == projectId }.sortedByDescending { it.startedAt }
