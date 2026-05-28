package app.rxlab.rxcode.state

import android.os.Build
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.rxlab.rxcode.BuildConfig
import app.rxlab.rxcode.proto.BranchOpRequestPayload
import app.rxlab.rxcode.proto.CancelStreamPayload
import app.rxlab.rxcode.proto.LoadMoreMessagesRequestPayload
import app.rxlab.rxcode.proto.MobileRunTaskSnapshot
import app.rxlab.rxcode.proto.NewSessionRequestPayload
import app.rxlab.rxcode.proto.PairRequestPayload
import app.rxlab.rxcode.proto.Payload
import app.rxlab.rxcode.proto.PermissionMode
import app.rxlab.rxcode.proto.PermissionResponsePayload
import app.rxlab.rxcode.proto.PongPayload
import app.rxlab.rxcode.proto.QuestionAnswerEntry
import app.rxlab.rxcode.proto.QuestionAnswerPayload
import app.rxlab.rxcode.proto.RequestSnapshotPayload
import app.rxlab.rxcode.proto.RunProfile
import app.rxlab.rxcode.proto.RunProfileMutationRequestPayload
import app.rxlab.rxcode.proto.RunProfileRunRequestPayload
import app.rxlab.rxcode.proto.RunProfileStopRequestPayload
import app.rxlab.rxcode.proto.SessionUpdatePayload
import app.rxlab.rxcode.proto.SubscribeSessionPayload
import app.rxlab.rxcode.proto.ThreadActionRequestPayload
import app.rxlab.rxcode.proto.ThreadChangesRequestPayload
import app.rxlab.rxcode.proto.UserMessagePayload
import app.rxlab.rxcode.pairing.PairingToken
import app.rxlab.rxcode.push.FcmTokenReporter
import app.rxlab.rxcode.relay.RelayClient
import app.rxlab.rxcode.store.PairedDesktop
import app.rxlab.rxcode.store.PairingStore
import app.rxlab.rxcode.sync.SyncClient
import com.google.firebase.messaging.FirebaseMessaging
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

/**
 * Mirrors iOS `MobileAppState` — owns the [SyncClient], persists pairings, and
 * exposes the UI-facing [MobileState] as a single [StateFlow].
 *
 * Intent methods (e.g. [sendUserMessage], [cancelStream]) translate UI actions
 * into encrypted payloads addressed at the active desktop, and update local
 * state optimistically where the iOS app does the same (e.g. injecting a draft
 * thread id while waiting for the desktop's authoritative reply).
 */
@HiltViewModel
class MobileAppState @Inject constructor(
    private val store: PairingStore,
    private val client: SyncClient,
    private val fcmTokenReporter: FcmTokenReporter,
) : ViewModel() {
    private val _state = MutableStateFlow(MobileState(relayUrl = defaultRelayUrl()))
    val state: StateFlow<MobileState> = _state.asStateFlow()

    private var started = false
    private var pairingTimeout: Job? = null
    private var pendingThreadChangesId: UUID? = null

    init {
        viewModelScope.launch { observeStore() }
        viewModelScope.launch { observeSyncEvents() }
    }

    fun start() {
        if (started) return
        started = true
        viewModelScope.launch {
            // Wire any already-paired peers before opening the socket so the
            // first inbound envelope decrypts cleanly.
            _state.value.pairedDesktops.forEach { client.addPeer(it.pubkeyHex) }
            client.start()
            if (_state.value.isPaired) {
                requestSnapshot("client_start")
                // Re-publish the FCM token on every cold start. Existing pairings
                // made before this device had Firebase wired up never delivered
                // a token, so the desktop shows "No push" forever otherwise.
                refreshAndReportFcmToken("client_start")
            }
        }
    }

    fun handleAppForeground() {
        if (!started) return
        viewModelScope.launch { client.start() }
    }

    fun handleAppBackground() {
        if (!started) return
        viewModelScope.launch { client.stop() }
    }

    // MARK: - Store

    private suspend fun observeStore() {
        combine(
            store.pairedDesktops,
            store.activeDesktopId,
            store.relayUrl,
        ) { paired, activeId, relay ->
            Triple(paired, activeId, relay)
        }.collect { (paired, activeId, relay) ->
            val active = paired
                .firstOrNull { it.id == activeId }
                ?.pubkeyHex
                ?: paired.firstOrNull()?.pubkeyHex
                ?: ""
            val resolvedRelay = (relay ?: paired.firstOrNull()?.relayUrl ?: defaultRelayUrl())
            // Sync peers + relay with the new persisted snapshot.
            paired.forEach { client.addPeer(it.pubkeyHex) }
            if (resolvedRelay != _state.value.relayUrl) client.setRelayUrl(resolvedRelay)
            _state.update { it.copy(pairedDesktops = paired, activeDesktopPubkey = active, relayUrl = resolvedRelay) }
        }
    }

    // MARK: - Inbound

    private suspend fun observeSyncEvents() {
        client.events.collect { event ->
            when (event) {
                is SyncClient.Event.StateChanged ->
                    _state.update { it.copy(connectionState = event.state) }

                is SyncClient.Event.DeliveryFailed ->
                    Log.w(TAG, "delivery failed to ${event.toHex.take(12)}")

                is SyncClient.Event.Inbound -> handleInbound(event.fromHex, event.payload)
            }
            if (event is SyncClient.Event.StateChanged &&
                event.state == RelayClient.ConnectionState.CONNECTED &&
                _state.value.isPaired
            ) {
                requestSnapshot("relay_connected")
            }
        }
    }

    private suspend fun handleInbound(fromHex: String, payload: Payload) {
        when (payload) {
            is Payload.PairAck -> handlePairAck(fromHex, payload)
            is Payload.Unpair -> handleUnpair(fromHex)
            is Payload.Snapshot -> handleSnapshot(fromHex, payload)
            is Payload.MoreMessages -> handleMoreMessages(fromHex, payload)
            is Payload.SessionUpdate -> handleSessionUpdate(fromHex, payload)
            is Payload.PermissionRequest -> {
                if (!isActiveDesktop(fromHex)) return
                _state.update { it.copy(pendingPermission = payload.data) }
            }
            is Payload.QuestionQueue -> {
                if (!isActiveDesktop(fromHex)) return
                _state.update { it.copy(pendingQuestions = payload.data.questions) }
            }
            is Payload.BranchOpResult -> {
                if (!isActiveDesktop(fromHex)) return
                _state.update { it.copy(pendingBranchOps = it.pendingBranchOps - payload.data.projectID) }
                if (payload.data.ok) requestSnapshot("branch_op_${payload.data.operation.name}")
                else Log.w(TAG, "branch op ${payload.data.operation.name} failed: ${payload.data.errorMessage}")
            }
            is Payload.RunProfileResult -> handleRunProfileResult(fromHex, payload.data)
            is Payload.RunTaskUpdate -> handleRunTaskUpdate(fromHex, payload.data.task)
            is Payload.ThreadChangesResult -> handleThreadChangesResult(fromHex, payload.data)
            is Payload.Ping -> {
                // Reply with pong to satisfy the desktop's liveness check.
                client.send(Payload.Pong(PongPayload()), fromHex)
            }
            else -> { /* ignored in Phase 1 */ }
        }
    }

    private suspend fun handlePairAck(fromHex: String, ack: Payload.PairAck) {
        Log.w(TAG, "pair_ack received from ${fromHex.take(12)} accepted=${ack.data.accepted}")
        pairingTimeout?.cancel()
        pairingTimeout = null
        if (!ack.data.accepted) {
            Log.w(TAG, "pair_ack rejected by desktop ${fromHex.take(12)}: ${ack.data.reason ?: "no reason"}")
            _state.update {
                it.copy(pairing = PairingStatus.Failed(ack.data.reason ?: "Your Mac declined the pairing request."))
            }
            return
        }
        val desktop = PairedDesktop(
            pubkeyHex = fromHex,
            displayName = ack.data.desktopName,
            pairedAtEpochMs = System.currentTimeMillis(),
            lastSeenEpochMs = System.currentTimeMillis(),
            relayUrl = _state.value.relayUrl,
        )
        store.upsert(desktop)
        store.setActive(desktop.id)
        _state.update { it.copy(pairing = PairingStatus.Idle) }
        client.addPeer(fromHex)
        Log.w(TAG, "pairing stored for desktop ${fromHex.take(12)} (${desktop.displayName})")
        refreshAndReportFcmToken("paired")
        requestSnapshot("paired")
    }

    private suspend fun handleUnpair(fromHex: String) {
        val desktop = _state.value.pairedDesktops.firstOrNull { it.pubkeyHex == fromHex } ?: return
        store.remove(desktop.id)
        client.removePeer(fromHex)
    }

    private fun handleSnapshot(fromHex: String, snap: Payload.Snapshot) {
        if (!isActiveDesktop(fromHex)) return
        _state.update { current ->
            val nextMessages = current.messagesBySession.toMutableMap()
            val moreSet = current.sessionsWithMoreMessages.toMutableSet()
            val loadingMore = current.loadingMoreSessions.toMutableSet()
            val nextRedirects = current.sessionIDRedirects.toMutableMap()
            val active = snap.data.activeSessionID
            // When the desktop tells us about a real session ID and our local
            // activeSessionID is still the optimistic draft from
            // `startNewSession`, set up a redirect so any composable still
            // holding the draft id (e.g. the chat screen we just navigated to)
            // resolves through to the real id and sees the snapshot's messages.
            val currentActive = current.activeSessionID
            if (active != null && currentActive != null && currentActive != active && isDraftSessionId(currentActive)) {
                nextRedirects[currentActive] = active
                val carried = nextMessages.remove(currentActive)
                if (carried != null && carried.isNotEmpty()) {
                    val existing = nextMessages[active].orEmpty()
                    val existingIDs = existing.map { it.id }.toHashSet()
                    nextMessages[active] = carried.filter { it.id !in existingIDs } + existing
                }
            }
            if (active != null) {
                val msgs = snap.data.activeSessionMessages
                if (msgs != null) {
                    nextMessages[active] = msgs
                    if (snap.data.activeSessionHasMore == true) moreSet.add(active) else moreSet.remove(active)
                    loadingMore.remove(active)
                } else if (nextMessages[active] == null) {
                    nextMessages[active] = emptyList()
                }
            }
            current.copy(
                projects = snap.data.projects,
                sessions = snap.data.sessions.sortedWith(SessionSort),
                // The snapshot's activeSessionID is metadata that labels the
                // carried activeSessionMessages — it must not be treated as a
                // navigation command. Only adopt it when our local selection
                // is the optimistic draft id produced by startNewSession and
                // the redirect map (set up above) confirms this snapshot is
                // the desktop's reply assigning the real id. Any other case
                // (reconnect, periodic refresh, desktop-focus change) leaves
                // the user's current selection alone.
                activeSessionID = if (
                    active != null &&
                    currentActive != null &&
                    isDraftSessionId(currentActive) &&
                    nextRedirects[currentActive] == active
                ) {
                    active
                } else {
                    current.activeSessionID
                },
                sessionIDRedirects = nextRedirects,
                messagesBySession = nextMessages,
                sessionsWithMoreMessages = moreSet,
                loadingMoreSessions = loadingMore,
                loadingThreadMessageSessions = if (active != null && snap.data.activeSessionMessages != null) {
                    current.loadingThreadMessageSessions - active
                } else {
                    current.loadingThreadMessageSessions
                },
                branchBriefings = snap.data.branchBriefings ?: current.branchBriefings,
                threadSummaries = snap.data.threadSummaries ?: current.threadSummaries,
                projectBranches = snap.data.projectBranches
                    ?.associateBy { it.projectId }
                    ?: current.projectBranches,
                runProfilesByProject = snap.data.runProfiles
                    ?.associate { it.projectId to it.profiles }
                    ?: current.runProfilesByProject,
                runTasks = snap.data.runTasks ?: current.runTasks,
                desktopWebProxy = snap.data.webProxy ?: current.desktopWebProxy,
                hasReceivedInitialSnapshot = true,
            )
        }
    }

    private fun handleMoreMessages(fromHex: String, more: Payload.MoreMessages) {
        if (!isActiveDesktop(fromHex)) return
        _state.update { current ->
            val sid = current.resolveSessionId(more.data.sessionID)
            val existing = current.messagesBySession[sid].orEmpty()
            val existingIDs = existing.map { it.id }.toHashSet()
            val older = more.data.messages.filter { it.id !in existingIDs }
            val nextMessages = current.messagesBySession.toMutableMap().apply {
                this[sid] = older + existing
            }
            val moreSet = current.sessionsWithMoreMessages.toMutableSet().apply {
                if (more.data.hasMore) add(sid) else remove(sid)
            }
            val loadingMore = current.loadingMoreSessions.toMutableSet().apply { remove(sid) }
            current.copy(
                messagesBySession = nextMessages,
                sessionsWithMoreMessages = moreSet,
                loadingMoreSessions = loadingMore,
            )
        }
    }

    private fun handleSessionUpdate(fromHex: String, update: Payload.SessionUpdate) {
        if (!isActiveDesktop(fromHex)) return
        _state.update { current ->
            var next = current
            val previous = update.data.previousSessionID
            if (previous != null && previous != update.data.sessionID) {
                val redirects = current.sessionIDRedirects.toMutableMap()
                redirects[previous] = update.data.sessionID
                redirects.entries
                    .filter { it.value == previous }
                    .forEach { redirects[it.key] = update.data.sessionID }
                val msgs = current.messagesBySession.toMutableMap()
                val carried = msgs.remove(previous)
                if (carried != null) {
                    val existing = msgs[update.data.sessionID].orEmpty()
                    msgs[update.data.sessionID] = if (existing.isEmpty()) {
                        carried
                    } else {
                        val existingIDs = existing.map { it.id }.toHashSet()
                        carried.filter { it.id !in existingIDs } + existing
                    }
                }
                val moreSet = current.sessionsWithMoreMessages.toMutableSet().also {
                    if (it.remove(previous)) it.add(update.data.sessionID)
                }
                val loadingMore = current.loadingMoreSessions.toMutableSet().also {
                    if (it.remove(previous)) it.add(update.data.sessionID)
                }
                val loadingThreadMessages = current.loadingThreadMessageSessions.toMutableSet().also {
                    if (it.remove(previous)) it.add(update.data.sessionID)
                }
                next = next.copy(
                    sessionIDRedirects = redirects,
                    messagesBySession = msgs,
                    sessionsWithMoreMessages = moreSet,
                    loadingMoreSessions = loadingMore,
                    loadingThreadMessageSessions = loadingThreadMessages,
                    activeSessionID = if (next.activeSessionID == previous) update.data.sessionID else next.activeSessionID,
                    sessions = next.sessions.filter { it.id != previous },
                )
            }

            // Per-session summary + streaming/thinking flags.
            val summary = update.data.summary
            val withSummary = if (summary != null) {
                val sessions = next.sessions.toMutableList()
                val idx = sessions.indexOfFirst { it.id == summary.id }
                if (idx >= 0) sessions[idx] = summary else sessions.add(summary)
                next.copy(sessions = sessions.sortedWith(SessionSort))
            } else next

            val thinking = withSummary.thinkingSessions.toMutableSet()
            update.data.isThinking?.let { if (it) thinking.add(update.data.sessionID) else thinking.remove(update.data.sessionID) }
            if (update.data.isStreaming == false) thinking.remove(update.data.sessionID)

            val msgs = withSummary.messagesBySession.toMutableMap()
            val sid = update.data.sessionID
            when (update.data.kind) {
                SessionUpdatePayload.Kind.MESSAGE_APPENDED -> update.data.message?.let { m ->
                    msgs[sid] = (msgs[sid].orEmpty() + m)
                }
                SessionUpdatePayload.Kind.MESSAGE_UPDATED -> update.data.message?.let { m ->
                    val list = msgs[sid]?.toMutableList() ?: return@let
                    val idx = list.indexOfFirst { it.id == m.id }
                    if (idx >= 0) { list[idx] = m; msgs[sid] = list }
                }
                else -> Unit
            }

            val loadingThreadMessages = withSummary.loadingThreadMessageSessions - sid
            withSummary.copy(
                messagesBySession = msgs,
                thinkingSessions = thinking,
                loadingThreadMessageSessions = loadingThreadMessages,
            )
        }
    }

    // MARK: - Intents

    fun requestSnapshot(reason: String = "manual") {
        viewModelScope.launch {
            val activeHex = _state.value.activeDesktopPubkey
            if (activeHex.isEmpty()) return@launch
            client.send(
                Payload.RequestSnapshot(RequestSnapshotPayload(activeSessionID = _state.value.activeSessionID)),
                activeHex,
            )
            Log.i(TAG, "snapshot requested ($reason)")
        }
    }

    /**
     * Buffers a session id from a tapped FCM notification. `RxCodeApp`
     * observes [MobileState.pendingNotificationSessionID] and routes the UI
     * (switch to Projects tab + select the session) once the app has finished
     * splash/onboarding gating. Buffered values survive cold launch because
     * `MainActivity` re-posts them on every `onCreate`/`onNewIntent`.
     */
    fun openThreadFromNotification(sessionId: String) {
        if (sessionId.isBlank()) return
        Log.i(TAG, "notification tap -> open thread sessionID=${sessionId.take(8)}")
        _state.update { it.copy(pendingNotificationSessionID = sessionId) }
    }

    fun consumePendingNotificationDeepLink() {
        _state.update { it.copy(pendingNotificationSessionID = null) }
    }

    fun selectSession(sessionId: String?) {
        val resolvedSessionId = sessionId?.let { _state.value.resolveSessionId(it) }
        _state.update {
            it.copy(
                activeSessionID = sessionId,
                loadingThreadMessageSessions = resolvedSessionId?.let { id -> setOf(id) } ?: emptySet(),
            )
        }
        viewModelScope.launch {
            val hex = _state.value.activeDesktopPubkey
            if (hex.isEmpty()) return@launch
            client.send(Payload.SubscribeSession(SubscribeSessionPayload(sessionID = sessionId)), hex)
            if (sessionId != null) requestSnapshot("session_selected")
        }
    }

    fun sendUserMessage(text: String) {
        val sessionId = _state.value.activeSessionID ?: return
        val resolved = _state.value.resolveSessionId(sessionId)
        viewModelScope.launch {
            client.send(
                Payload.UserMessage(
                    UserMessagePayload(sessionID = resolved, text = text)
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    fun cancelStream() {
        val sessionId = _state.value.activeSessionID ?: return
        val resolved = _state.value.resolveSessionId(sessionId)
        viewModelScope.launch {
            client.send(Payload.CancelStream(CancelStreamPayload(sessionID = resolved)), _state.value.activeDesktopPubkey)
        }
    }

    fun loadMoreMessages() {
        val sid = _state.value.activeSessionID ?: return
        val resolved = _state.value.resolveSessionId(sid)
        if (!_state.value.sessionsWithMoreMessages.contains(resolved)) return
        val first = _state.value.messagesBySession[resolved]?.firstOrNull() ?: return
        _state.update { it.copy(loadingMoreSessions = it.loadingMoreSessions + resolved) }
        viewModelScope.launch {
            client.send(
                Payload.LoadMoreMessages(
                    LoadMoreMessagesRequestPayload(
                        sessionID = resolved,
                        beforeMessageID = first.id,
                        limit = MESSAGE_PAGE_SIZE,
                    )
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    fun startNewSession(
        projectId: UUID,
        initialText: String? = null,
        planMode: Boolean = false,
        permissionMode: PermissionMode? = null,
    ): String {
        val draftId = draftSessionId(projectId)
        _state.update { it.copy(activeSessionID = draftId, messagesBySession = it.messagesBySession + (draftId to emptyList())) }
        viewModelScope.launch {
            client.send(
                Payload.NewSessionRequest(
                    NewSessionRequestPayload(
                        projectID = projectId,
                        initialText = initialText,
                        planMode = planMode.takeIf { it },
                        permissionMode = permissionMode,
                    )
                ),
                _state.value.activeDesktopPubkey,
            )
        }
        return draftId
    }

    /**
     * Ask the desktop to `git init` the project root. Used by the Briefing
     * detail screen when the project's resolved branch is `"unknown"`. The
     * desktop replies with `branch_op_result`; the inbound handler clears
     * [MobileState.pendingBranchOps] and refreshes the snapshot so the new
     * branch info ("main", etc.) appears.
     */
    fun initProjectGit(projectId: UUID) {
        if (_state.value.pendingBranchOps.contains(projectId)) return
        _state.update { it.copy(pendingBranchOps = it.pendingBranchOps + projectId) }
        viewModelScope.launch {
            client.send(
                Payload.BranchOpRequest(
                    BranchOpRequestPayload(
                        projectID = projectId,
                        operation = BranchOpRequestPayload.Operation.INIT_GIT,
                        branch = "",
                    )
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    fun renameThread(sessionId: String, newTitle: String) = threadAction(
        sessionId, ThreadActionRequestPayload.ThreadAction.RENAME, newTitle
    )

    fun archiveThread(sessionId: String) = threadAction(
        sessionId, ThreadActionRequestPayload.ThreadAction.ARCHIVE, null
    )

    fun deleteThread(sessionId: String) = threadAction(
        sessionId, ThreadActionRequestPayload.ThreadAction.DELETE, null
    )

    private fun threadAction(
        sessionId: String,
        action: ThreadActionRequestPayload.ThreadAction,
        newTitle: String?,
    ) {
        viewModelScope.launch {
            client.send(
                Payload.ThreadActionRequest(
                    ThreadActionRequestPayload(sessionID = sessionId, action = action, newTitle = newTitle)
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    fun respondToPermission(allow: Boolean, denyReason: String? = null) {
        val req = _state.value.pendingPermission ?: return
        _state.update { it.copy(pendingPermission = null) }
        viewModelScope.launch {
            client.send(
                Payload.PermissionResponse(
                    PermissionResponsePayload(requestID = req.requestID, allow = allow, denyReason = denyReason)
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    fun answerQuestion(toolUseID: String, answers: List<QuestionAnswerEntry>) {
        _state.update { it.copy(pendingQuestions = it.pendingQuestions.filterNot { q -> q.toolUseID == toolUseID }) }
        viewModelScope.launch {
            client.send(
                Payload.QuestionAnswer(QuestionAnswerPayload(toolUseID, answers)),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    // MARK: - Run profiles

    private fun handleRunProfileResult(
        fromHex: String,
        result: app.rxlab.rxcode.proto.RunProfileResultPayload,
    ) {
        if (!isActiveDesktop(fromHex)) return
        if (!result.ok) {
            Log.w(TAG, "run profile op failed for project=${result.projectID}: ${result.errorMessage}")
            return
        }
        _state.update { current ->
            var next = current
            result.profiles?.let { profiles ->
                next = next.copy(
                    runProfilesByProject = next.runProfilesByProject + (result.projectID to profiles),
                )
            }
            result.task?.let { task ->
                next = next.copy(runTasks = mergeRunTask(next.runTasks, task))
            }
            next
        }
    }

    private fun handleRunTaskUpdate(fromHex: String, task: MobileRunTaskSnapshot) {
        if (!isActiveDesktop(fromHex)) return
        _state.update { it.copy(runTasks = mergeRunTask(it.runTasks, task)) }
    }

    private fun mergeRunTask(
        existing: List<MobileRunTaskSnapshot>,
        task: MobileRunTaskSnapshot,
    ): List<MobileRunTaskSnapshot> {
        val list = existing.toMutableList()
        val idx = list.indexOfFirst { it.taskId == task.taskId }
        if (idx >= 0) list[idx] = task else list.add(task)
        return list
    }

    /** Ask the desktop to start the run profile. */
    fun runRunProfile(projectId: UUID, profileId: UUID) {
        viewModelScope.launch {
            client.send(
                Payload.RunProfileRunRequest(
                    RunProfileRunRequestPayload(projectID = projectId, profileID = profileId)
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    /** Stop the running task (by task id, falling back to profile id). */
    fun stopRunTask(taskId: UUID? = null, projectId: UUID? = null, profileId: UUID? = null) {
        viewModelScope.launch {
            client.send(
                Payload.RunProfileStopRequest(
                    RunProfileStopRequestPayload(
                        taskID = taskId,
                        projectID = projectId,
                        profileID = profileId,
                    )
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    /** Create or update a run profile. The desktop replies with the new list. */
    fun upsertRunProfile(profile: RunProfile) {
        viewModelScope.launch {
            client.send(
                Payload.RunProfileMutationRequest(
                    RunProfileMutationRequestPayload(
                        projectID = profile.projectId,
                        operation = RunProfileMutationRequestPayload.Operation.UPSERT,
                        profile = profile,
                    )
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    fun deleteRunProfile(projectId: UUID, profileId: UUID) {
        viewModelScope.launch {
            client.send(
                Payload.RunProfileMutationRequest(
                    RunProfileMutationRequestPayload(
                        projectID = projectId,
                        operation = RunProfileMutationRequestPayload.Operation.DELETE,
                        profileID = profileId,
                    )
                ),
                _state.value.activeDesktopPubkey,
            )
        }
    }

    // MARK: - Thread changes

    /**
     * Ask the desktop for the changes (per-turn file edits + uncommitted git
     * changes) for [sessionId]. Mirrors iOS `requestThreadChanges`: tracks the
     * latest request id so a stale response is dropped, and toggles
     * [MobileState.isLoadingThreadChanges] for the sheet's loading UI.
     */
    fun requestThreadChanges(sessionId: String) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) return
        val resolved = _state.value.resolveSessionId(sessionId)
        val requestId = UUID.randomUUID()
        pendingThreadChangesId = requestId
        _state.update { it.copy(isLoadingThreadChanges = true) }
        viewModelScope.launch {
            val sent = client.send(
                Payload.ThreadChangesRequest(
                    ThreadChangesRequestPayload(clientRequestID = requestId, sessionID = resolved)
                ),
                hex,
            )
            if (!sent && pendingThreadChangesId == requestId) {
                pendingThreadChangesId = null
                _state.update { it.copy(isLoadingThreadChanges = false) }
            }
        }
    }

    private fun handleThreadChangesResult(
        fromHex: String,
        result: app.rxlab.rxcode.proto.ThreadChangesResultPayload,
    ) {
        if (!isActiveDesktop(fromHex)) return
        val pending = pendingThreadChangesId ?: return
        if (result.clientRequestID != pending) return
        pendingThreadChangesId = null
        _state.update { it.copy(threadChanges = result, isLoadingThreadChanges = false) }
    }

    // MARK: - Pairing

    fun beginPairing(token: PairingToken, displayName: String = defaultDisplayName()) {
        Log.w(
            TAG,
            "beginPairing requested for desktop=${token.desktopName.ifBlank { "unknown" }} " +
                "pubkey=${token.desktopPubkeyHex.take(12)} relay=${token.relayURL} " +
                "expiresAt=${token.expiresAt} expired=${token.isExpired}",
        )
        if (_state.value.pairing is PairingStatus.InProgress) {
            Log.w(TAG, "beginPairing ignored because another pairing request is already in progress")
            return
        }
        if (token.isExpired) {
            Log.w(TAG, "beginPairing rejected expired token for desktop ${token.desktopPubkeyHex.take(12)}")
            _state.update { it.copy(pairing = PairingStatus.Failed("The pairing QR code has expired. Generate a fresh one on your Mac.")) }
            return
        }
        _state.update { it.copy(pairing = PairingStatus.InProgress) }
        viewModelScope.launch {
            try {
                Log.w(TAG, "pairing relay setup: relay=${token.relayURL} desktop=${token.desktopPubkeyHex.take(12)}")
                store.setRelayUrl(token.relayURL)
                client.setRelayUrl(token.relayURL)
                client.addPeer(token.desktopPubkeyHex)
                client.start()

                // Wait briefly for the socket to connect; iOS uses 25s.
                Log.w(TAG, "waiting for relay connection before sending pair_request")
                val connected = withTimeoutOrNull(PAIRING_TIMEOUT_MS) {
                    client.connectionState.first { it == RelayClient.ConnectionState.CONNECTED }
                    true
                } ?: false
                if (!connected) {
                    Log.w(TAG, "pairing relay connection timed out after ${PAIRING_TIMEOUT_MS}ms")
                    _state.update { it.copy(pairing = PairingStatus.Failed("Couldn't reach the relay. Make sure your Mac is online and try again.")) }
                    return@launch
                }

                Log.w(TAG, "relay connected; sending pair_request to ${token.desktopPubkeyHex.take(12)}")
                val enqueued = client.send(
                    Payload.PairRequest(
                        PairRequestPayload(
                            mobilePubkeyHex = client.identity.publicKeyHex,
                            displayName = displayName.ifBlank { defaultDisplayName() },
                            platform = "Android",
                            appVersion = BuildConfig.VERSION_NAME,
                        )
                    ),
                    token.desktopPubkeyHex,
                )
                Log.w(TAG, "pair_request enqueue result=$enqueued")
                if (!enqueued) {
                    _state.update { it.copy(pairing = PairingStatus.Failed("Couldn't send the pairing request. Try scanning again.")) }
                    return@launch
                }

                pairingTimeout?.cancel()
                pairingTimeout = launch {
                    delay(PAIRING_TIMEOUT_MS)
                    if (_state.value.pairing == PairingStatus.InProgress) {
                        Log.w(TAG, "pair_ack timed out after ${PAIRING_TIMEOUT_MS}ms")
                        _state.update { it.copy(pairing = PairingStatus.Failed("No response from your Mac. Regenerate the QR code and try again.")) }
                    }
                }
            } catch (t: Throwable) {
                Log.e(TAG, "beginPairing failed: ${t.message}", t)
                _state.update { it.copy(pairing = PairingStatus.Failed("Pairing failed before the request could be sent. Try scanning again.")) }
            }
        }
    }

    fun clearPairingError() {
        if (_state.value.pairing is PairingStatus.Failed) {
            _state.update { it.copy(pairing = PairingStatus.Idle) }
        }
    }

    fun switchActiveDesktop(desktop: PairedDesktop) {
        viewModelScope.launch {
            store.setActive(desktop.id)
            desktop.relayUrl?.let {
                store.setRelayUrl(it)
                client.setRelayUrl(it)
            }
            requestSnapshot("desktop_switched")
        }
    }

    fun removeDesktop(desktop: PairedDesktop) {
        viewModelScope.launch {
            store.remove(desktop.id)
            client.removePeer(desktop.pubkeyHex)
        }
    }

    // MARK: - Helpers

    private fun isActiveDesktop(fromHex: String): Boolean = _state.value.activeDesktopPubkey == fromHex

    private fun refreshAndReportFcmToken(reason: String) {
        try {
            FirebaseMessaging.getInstance().token
                .addOnSuccessListener { token ->
                    viewModelScope.launch { fcmTokenReporter.report(token) }
                    Log.w(TAG, "FCM token refresh requested reason=$reason token=${token.take(12)}")
                }
                .addOnFailureListener { error ->
                    Log.w(TAG, "FCM token refresh failed reason=$reason: ${error.message}")
                }
        } catch (t: Throwable) {
            Log.w(TAG, "FCM token unavailable reason=$reason: ${t.message}")
        }
    }

    companion object {
        private const val TAG = "MobileAppState"
        private const val PAIRING_TIMEOUT_MS = 25_000L
        const val MESSAGE_PAGE_SIZE = 30

        fun defaultDisplayName(): String = Build.MODEL.ifBlank { "Android" }

        fun defaultRelayUrl(): String =
            if (BuildConfig.DEBUG) "ws://10.0.2.2:8787/ws" else "wss://relay.rxlab.app/ws"
    }
}

private object SessionSort : Comparator<app.rxlab.rxcode.proto.SessionSummary> {
    override fun compare(a: app.rxlab.rxcode.proto.SessionSummary, b: app.rxlab.rxcode.proto.SessionSummary): Int {
        if (a.isPinned != b.isPinned) return if (a.isPinned) -1 else 1
        return b.updatedAt.compareTo(a.updatedAt)
    }
}
