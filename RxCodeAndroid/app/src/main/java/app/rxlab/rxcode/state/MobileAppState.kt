package app.rxlab.rxcode.state

import android.content.Context
import android.os.Build
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.rxlab.rxcode.BuildConfig
import app.rxlab.rxcode.proto.AutopilotProjectSecretsDownloadResult
import app.rxlab.rxcode.proto.AutopilotProjectSecretsWriteBody
import app.rxlab.rxcode.proto.AutopilotProjectStatus
import app.rxlab.rxcode.proto.BranchOpRequestPayload
import app.rxlab.rxcode.proto.CancelStreamPayload
import app.rxlab.rxcode.proto.CreateProjectRequestPayload
import app.rxlab.rxcode.proto.DeleteProjectRequestPayload
import app.rxlab.rxcode.proto.FolderTreeRequestPayload
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
import app.rxlab.rxcode.proto.SecretsManagedRepo
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
    private var pendingFolderTreeRequestId: UUID? = null
    private var pendingCreateProjectId: UUID? = null
    private var pendingThreadChangesId: UUID? = null
    private var pendingDeleteProjectId: UUID? = null
    private var searchJob: Job? = null

    // Remote-config (MCP / ACP / Skills) request correlation, mirroring the
    // iOS `MobileAppState+RemoteConfig` stored properties. Touched only from
    // viewModelScope coroutines (Main dispatcher), so no extra synchronization.
    private var pendingMCPConfigRequestID: UUID? = null
    private var pendingACPRegistryRequestID: UUID? = null
    private var pendingSkillCatalogRequestID: UUID? = null
    private val acpMutationKeys = mutableMapOf<UUID, String>()
    private val skillSourceMutationKeys = mutableMapOf<UUID, String>()

    /**
     * Autopilot remote-management round-trips (mirrors the desktop's Autopilot
     * settings tab). Sends through the same encrypted [client]; replies are
     * routed back in [handleInbound] via [AutopilotService.handleResult].
     */
    val autopilot: AutopilotService = AutopilotService(
        send = { payload, hex -> client.send(payload, hex) },
        activeDesktopHex = { _state.value.activeDesktopPubkey.takeIf { it.isNotEmpty() } },
    )

    /** On-device secrets crypto orchestration (passkey-derived KEK + relay). */
    val secrets: SecretsManager = SecretsManager(autopilot)

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
                ?: paired.firstOrNull()
            val activeHex = active?.pubkeyHex ?: ""
            val activeCompositeId = active?.id ?: ""
            val resolvedRelay = (relay ?: active?.relayUrl ?: paired.firstOrNull()?.relayUrl ?: defaultRelayUrl())
            // Sync peers + relay with the new persisted snapshot.
            paired.forEach { client.addPeer(it.pubkeyHex) }
            if (resolvedRelay != _state.value.relayUrl) client.setRelayUrl(resolvedRelay)
            _state.update {
                val desktopChanged = it.activeDesktopId != activeCompositeId ||
                    it.activeDesktopPubkey != activeHex
                it.copy(
                    pairedDesktops = paired,
                    activeDesktopId = activeCompositeId,
                    activeDesktopPubkey = activeHex,
                    relayUrl = resolvedRelay,
                    hasReceivedInitialSnapshot = if (desktopChanged) false else it.hasReceivedInitialSnapshot,
                    acpRegistryLoading = if (desktopChanged) false else it.acpRegistryLoading,
                    skillCatalogLoading = if (desktopChanged) false else it.skillCatalogLoading,
                    acpRegistryError = if (desktopChanged) null else it.acpRegistryError,
                    skillCatalogError = if (desktopChanged) null else it.skillCatalogError,
                )
            }
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
            is Payload.FolderTreeResult -> {
                if (!isActiveDesktop(fromHex)) return
                if (payload.data.clientRequestID != pendingFolderTreeRequestId) return
                pendingFolderTreeRequestId = null
                _state.update {
                    if (payload.data.ok && payload.data.root != null) {
                        it.copy(
                            remoteFolderRoot = payload.data.root,
                            remoteFolderIsLoading = false,
                            remoteFolderError = null,
                        )
                    } else {
                        it.copy(
                            remoteFolderIsLoading = false,
                            remoteFolderError = payload.data.errorMessage ?: "Failed to load folders.",
                        )
                    }
                }
            }
            is Payload.CreateProjectResult -> {
                if (!isActiveDesktop(fromHex)) return
                if (payload.data.clientRequestID != pendingCreateProjectId) return
                pendingCreateProjectId = null
                _state.update { current ->
                    if (payload.data.ok && payload.data.project != null) {
                        val project = payload.data.project
                        val projects = if (current.projects.any { it.id == project.id }) {
                            current.projects
                        } else {
                            current.projects + project
                        }
                        current.copy(
                            projects = projects,
                            remoteProjectCreateInFlight = false,
                            remoteProjectCreateError = null,
                            lastCreatedProjectID = project.id,
                        )
                    } else {
                        current.copy(
                            remoteProjectCreateInFlight = false,
                            remoteProjectCreateError = payload.data.errorMessage ?: "Failed to add project.",
                        )
                    }
                }
                if (payload.data.ok) requestSnapshot("create_project")
            }
            is Payload.DeleteProjectResult -> {
                if (!isActiveDesktop(fromHex)) return
                if (payload.data.clientRequestID != pendingDeleteProjectId) return
                pendingDeleteProjectId = null
                if (!payload.data.ok) {
                    Log.w(TAG, "delete project failed: ${payload.data.errorMessage}")
                    // Restore the optimistically-removed project from the desktop.
                    _state.update { it.copy(lastError = payload.data.errorMessage ?: "Couldn't delete the project.") }
                    requestSnapshot("delete_project_failed")
                }
            }
            is Payload.RunProfileResult -> handleRunProfileResult(fromHex, payload.data)
            is Payload.RunTaskUpdate -> handleRunTaskUpdate(fromHex, payload.data.task)
            is Payload.ThreadChangesResult -> handleThreadChangesResult(fromHex, payload.data)
            is Payload.AutopilotResult -> {
                if (!isActiveDesktop(fromHex)) return
                autopilot.handleResult(payload.data)
            }
            is Payload.MCPConfigResult -> {
                if (!isActiveDesktop(fromHex)) return
                applyMCPConfigResult(payload.data)
            }
            is Payload.MCPMutationResult -> {
                if (!isActiveDesktop(fromHex)) return
                applyMCPMutationResult(payload.data)
            }
            is Payload.ACPRegistryResult -> {
                if (!isActiveDesktop(fromHex)) {
                    Log.w(
                        TAG,
                        "acp registry result ignored inactive from=${fromHex.take(12)} " +
                            "active=${_state.value.activeDesktopPubkey.take(12)} id=${payload.data.clientRequestID}",
                    )
                    return
                }
                Log.w(
                    TAG,
                    "acp registry result inbound id=${payload.data.clientRequestID} ok=${payload.data.ok} " +
                        "agents=${payload.data.registryAgents.size} clients=${payload.data.installedClients.size}",
                )
                applyACPRegistryResult(payload.data)
            }
            is Payload.ACPMutationResult -> {
                if (!isActiveDesktop(fromHex)) return
                applyACPMutationResult(payload.data)
            }
            is Payload.SkillCatalogResult -> {
                if (!isActiveDesktop(fromHex)) {
                    Log.w(
                        TAG,
                        "skill catalog result ignored inactive from=${fromHex.take(12)} " +
                            "active=${_state.value.activeDesktopPubkey.take(12)} id=${payload.data.clientRequestID}",
                    )
                    return
                }
                Log.w(
                    TAG,
                    "skill catalog result inbound id=${payload.data.clientRequestID} ok=${payload.data.ok} " +
                        "plugins=${payload.data.plugins.size} sources=${payload.data.sources.size}",
                )
                applySkillCatalogResult(payload.data)
            }
            is Payload.SkillMutationResult -> {
                if (!isActiveDesktop(fromHex)) return
                applySkillMutationResult(payload.data)
            }
            is Payload.SkillSourceMutationResult -> {
                if (!isActiveDesktop(fromHex)) return
                applySkillSourceMutationResult(payload.data)
            }
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
        // The unpair arrived over the relay this client is currently connected to,
        // so it targets the pairing for that specific relay. Matching by pubkey
        // alone would remove an entry for the same Mac on a *different* relay
        // (see `PairedDesktop.matchForUnpair`).
        val desktop = PairedDesktop.matchForUnpair(
            desktops = _state.value.pairedDesktops,
            fromHex = fromHex,
            currentRelay = _state.value.relayUrl,
        ) ?: return
        store.remove(desktop.id)
        // Only forget the crypto peer if no other pairing uses the same pubkey
        // (e.g. the same Mac reached through another relay).
        if (_state.value.pairedDesktops.none { it.pubkeyHex == fromHex && it.id != desktop.id }) {
            client.removePeer(fromHex)
        }
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
                ciStatusByProject = snap.data.ciStatuses
                    ?.associate { it.projectId to it.status }
                    ?: current.ciStatusByProject,
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

    // MARK: - Project context-menu actions

    fun requestRemoteFolder(path: String? = null, includeFiles: Boolean = false) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) return
        val request = FolderTreeRequestPayload(path = path, depth = 1, includeFiles = includeFiles)
        pendingFolderTreeRequestId = request.clientRequestID
        _state.update {
            it.copy(
                remoteFolderIsLoading = true,
                remoteFolderError = null,
            )
        }
        viewModelScope.launch {
            val sent = client.send(Payload.FolderTreeRequest(request), hex)
            if (!sent && pendingFolderTreeRequestId == request.clientRequestID) {
                pendingFolderTreeRequestId = null
                _state.update {
                    it.copy(
                        remoteFolderIsLoading = false,
                        remoteFolderError = "Couldn't reach your Mac to load folders.",
                    )
                }
            }
        }
    }

    fun clearRemoteFolderError() {
        _state.update { it.copy(remoteFolderError = null) }
    }

    fun createProjectFromRemoteFolder(path: String) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) return
        val trimmed = path.trim()
        if (trimmed.isEmpty()) return
        val request = CreateProjectRequestPayload(path = trimmed)
        pendingCreateProjectId = request.clientRequestID
        _state.update {
            it.copy(
                remoteProjectCreateInFlight = true,
                remoteProjectCreateError = null,
                lastCreatedProjectID = null,
            )
        }
        viewModelScope.launch {
            val sent = client.send(Payload.CreateProjectRequest(request), hex)
            if (!sent && pendingCreateProjectId == request.clientRequestID) {
                pendingCreateProjectId = null
                _state.update {
                    it.copy(
                        remoteProjectCreateInFlight = false,
                        remoteProjectCreateError = "Couldn't reach your Mac to add the project.",
                    )
                }
            }
        }
    }

    fun clearRemoteProjectCreateError() {
        _state.update { it.copy(remoteProjectCreateError = null) }
    }

    suspend fun cloneAutopilotRepo(repo: SecretsManagedRepo): app.rxlab.rxcode.proto.Project {
        val project = autopilot.cloneManagedRepo(repo.fullName)
        _state.update { current ->
            val projects = if (current.projects.any { it.id == project.id }) {
                current.projects
            } else {
                current.projects + project
            }
            current.copy(projects = projects, lastCreatedProjectID = project.id)
        }
        requestSnapshot("clone_managed_repo")
        return project
    }

    /**
     * Cascade-delete a project on the desktop. Optimistically drops it (and its
     * sessions) from local state so the UI updates immediately; the desktop
     * confirms via `delete_project_result`. On failure [handleInbound] re-syncs
     * to restore the project.
     */
    fun deleteProject(projectId: UUID) {
        if (!_state.value.isPaired) return
        val request = DeleteProjectRequestPayload(projectID = projectId)
        pendingDeleteProjectId = request.clientRequestID
        _state.update {
            it.copy(
                projects = it.projects.filterNot { p -> p.id == projectId },
                sessions = it.sessions.filterNot { s -> s.projectId == projectId },
            )
        }
        viewModelScope.launch {
            val sent = client.send(Payload.DeleteProjectRequest(request), _state.value.activeDesktopPubkey)
            if (!sent) {
                pendingDeleteProjectId = null
                _state.update { it.copy(lastError = "Couldn't reach your Mac to delete the project.") }
                requestSnapshot("delete_project_send_failed")
            }
        }
    }

    /**
     * Per-project autopilot state (has secrets / docs / release), used by the
     * project context menu to choose the same items the desktop menu shows.
     */
    suspend fun projectAutopilotStatus(projectId: UUID): AutopilotProjectStatus =
        autopilot.projectAutopilotStatus(projectId)

    /** Open a PR for the project's branch on the Mac; returns the PR URL. */
    suspend fun requestProjectCreatePullRequest(projectId: UUID, branch: String): String =
        autopilot.requestProjectCreatePullRequest(projectId, branch)

    /** Start a `[Code Review]` thread on the Mac reviewing the whole branch; returns its id. */
    suspend fun requestProjectCreateCodeReview(projectId: UUID, branch: String): String =
        autopilot.requestProjectCreateCodeReview(projectId, branch)

    /** Start a `[Code Review]` thread on the Mac reviewing one thread's changes; returns its id. */
    suspend fun requestThreadCreateCodeReview(sessionId: String): String =
        autopilot.requestThreadCreateCodeReview(sessionId)

    /** Start a commit-only thread on the Mac for all current project changes. */
    suspend fun requestProjectCommitAll(projectId: UUID): String =
        autopilot.requestProjectCommitAll(projectId)

    /** Ask the Mac to commit only the files recorded for one thread. */
    suspend fun requestThreadCommitFiles(sessionId: String): String =
        autopilot.requestThreadCommitFiles(sessionId)

    /**
     * Download a secret environment into the project folder: decrypt on-device
     * with the passkey-derived KEK, then relay the plaintext for the Mac to write.
     * Mirrors iOS `downloadProjectSecrets`. Returns files written + conflicts.
     */
    suspend fun downloadProjectSecrets(
        context: Context,
        projectId: UUID,
        repo: String,
        envId: String,
        overwrite: Boolean,
    ): AutopilotProjectSecretsDownloadResult {
        val plaintext = secrets.environmentPlaintext(context, repo, envId)
        val files = plaintext.map { AutopilotProjectSecretsWriteBody.Plaintext(it.filename, it.content) }
        return autopilot.projectSecretsWrite(projectId, files, overwrite)
    }

    // MARK: - Global search

    /**
     * Run a combined threads + docs search for [query], debounced by 200 ms.
     * Mirrors iOS `updateSearchQuery`: a blank query clears results; otherwise one
     * `searchThreadsAndDocs` autopilot round trip populates both hit lists. Each
     * keystroke cancels the previous in-flight search so only the latest applies.
     */
    fun updateSearchQuery(query: String) {
        _state.update { it.copy(searchQuery = query) }
        searchJob?.cancel()
        val trimmed = query.trim()
        if (trimmed.isEmpty()) {
            _state.update {
                it.copy(
                    isSearching = false,
                    searchThreadHits = emptyList(),
                    searchDocHits = emptyList(),
                    searchProjectIDs = emptyList(),
                )
            }
            return
        }
        searchJob = viewModelScope.launch {
            delay(SEARCH_DEBOUNCE_MS)
            _state.update { it.copy(isSearching = true) }
            try {
                val result = autopilot.searchThreadsAndDocs(trimmed, limit = SEARCH_LIMIT)
                // Ignore stale results whose query no longer matches the field.
                if (_state.value.searchQuery.trim() != trimmed) return@launch
                _state.update {
                    it.copy(
                        isSearching = false,
                        searchThreadHits = result.threadHits,
                        searchDocHits = result.docHits,
                        searchProjectIDs = result.projectIDs,
                    )
                }
            } catch (t: Throwable) {
                if (_state.value.searchQuery.trim() != trimmed) return@launch
                Log.w(TAG, "search failed: ${t.message}")
                _state.update { it.copy(isSearching = false) }
            }
        }
    }

    /** Clear the search field and any results (e.g. when leaving the search UI). */
    fun clearSearch() {
        searchJob?.cancel()
        _state.update {
            it.copy(
                searchQuery = "",
                isSearching = false,
                searchThreadHits = emptyList(),
                searchDocHits = emptyList(),
                searchProjectIDs = emptyList(),
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

    // MARK: - Remote desktop configuration (MCP / ACP / Skills)
    //
    // 1:1 with iOS `MobileAppState+RemoteConfig`/`+Inbound`: each request is
    // correlated by `clientRequestID`; the desktop replies with the
    // authoritative list. A `delay` timeout clears a stuck request and surfaces
    // an error, exactly like iOS `scheduleTimeout`.

    // ---- MCP servers ----

    fun requestMCPConfig() {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) {
            _state.update { it.copy(mcpConfigError = "Connect a Mac to manage MCP servers.") }
            return
        }
        val payload = app.rxlab.rxcode.proto.MCPConfigRequestPayload()
        pendingMCPConfigRequestID = payload.clientRequestID
        _state.update { it.copy(mcpConfigLoading = true, mcpConfigError = null) }
        viewModelScope.launch {
            val sent = client.send(Payload.MCPConfigRequest(payload), hex)
            if (!sent) {
                if (pendingMCPConfigRequestID == payload.clientRequestID) pendingMCPConfigRequestID = null
                _state.update { it.copy(mcpConfigLoading = false, mcpConfigError = "Failed to request MCP servers.") }
                return@launch
            }
            delay(REMOTE_CONFIG_TIMEOUT_MS)
            if (pendingMCPConfigRequestID == payload.clientRequestID) {
                pendingMCPConfigRequestID = null
                _state.update { it.copy(mcpConfigLoading = false, mcpConfigError = REMOTE_TIMEOUT_MESSAGE) }
            }
        }
    }

    fun addMCPServer(server: app.rxlab.rxcode.proto.MobileMCPServer) =
        mutateMCP(app.rxlab.rxcode.proto.MCPMutationRequestPayload.Operation.ADD, server.name, server = server)

    fun removeMCPServer(serverName: String) =
        mutateMCP(app.rxlab.rxcode.proto.MCPMutationRequestPayload.Operation.REMOVE, serverName)

    fun setMCPServerEnabled(serverName: String, enabled: Boolean) =
        mutateMCP(
            app.rxlab.rxcode.proto.MCPMutationRequestPayload.Operation.SET_ENABLED,
            serverName,
            enabled = enabled,
        )

    private fun mutateMCP(
        operation: app.rxlab.rxcode.proto.MCPMutationRequestPayload.Operation,
        serverName: String,
        server: app.rxlab.rxcode.proto.MobileMCPServer? = null,
        enabled: Boolean? = null,
    ) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) {
            _state.update { it.copy(lastMCPError = "Connect a Mac first.") }
            return
        }
        if (_state.value.inFlightMCPMutations.contains(serverName)) return
        val payload = app.rxlab.rxcode.proto.MCPMutationRequestPayload(
            operation = operation,
            serverName = serverName,
            server = server,
            enabled = enabled,
        )
        _state.update {
            it.copy(inFlightMCPMutations = it.inFlightMCPMutations + serverName, lastMCPError = null)
        }
        viewModelScope.launch {
            val sent = client.send(Payload.MCPMutationRequest(payload), hex)
            if (!sent) {
                _state.update {
                    it.copy(
                        inFlightMCPMutations = it.inFlightMCPMutations - serverName,
                        lastMCPError = "Failed to send request.",
                    )
                }
                return@launch
            }
            delay(REMOTE_CONFIG_TIMEOUT_MS)
            if (_state.value.inFlightMCPMutations.contains(serverName)) {
                _state.update {
                    it.copy(
                        inFlightMCPMutations = it.inFlightMCPMutations - serverName,
                        lastMCPError = REMOTE_TIMEOUT_MESSAGE,
                    )
                }
            }
        }
    }

    private fun applyMCPConfigResult(result: app.rxlab.rxcode.proto.MCPConfigResultPayload) {
        if (pendingMCPConfigRequestID != result.clientRequestID) return
        pendingMCPConfigRequestID = null
        _state.update {
            it.copy(
                mcpConfigLoading = false,
                mcpServers = if (result.ok) result.servers else it.mcpServers,
                mcpConfigError = if (result.ok) null else (result.errorMessage ?: "Failed to load MCP servers."),
            )
        }
    }

    private fun applyMCPMutationResult(result: app.rxlab.rxcode.proto.MCPMutationResultPayload) {
        _state.update {
            it.copy(
                inFlightMCPMutations = it.inFlightMCPMutations - result.serverName,
                mcpServers = result.servers,
                lastMCPError = if (result.ok) null else (result.errorMessage ?: "MCP operation failed."),
            )
        }
    }

    // ---- ACP agent clients ----

    fun requestACPRegistry(forceRefresh: Boolean = false, retryOnTimeout: Boolean = true) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) {
            Log.w(TAG, "acp registry request skipped: no active desktop")
            pendingACPRegistryRequestID = null
            _state.update { it.copy(acpRegistryError = "Connect a Mac to manage agents.") }
            return
        }
        if (!_state.value.hasReceivedInitialSnapshot) {
            Log.w(TAG, "acp registry request skipped: waiting for initial snapshot")
            pendingACPRegistryRequestID = null
            _state.update { it.copy(acpRegistryLoading = false, acpRegistryError = null) }
            return
        }
        val payload = app.rxlab.rxcode.proto.ACPRegistryRequestPayload(forceRefresh = forceRefresh)
        pendingACPRegistryRequestID = payload.clientRequestID
        Log.w(
            TAG,
            "acp registry request start id=${payload.clientRequestID} forceRefresh=$forceRefresh " +
                "desktop=${hex.take(12)} connection=${_state.value.connectionState} " +
                "agents=${_state.value.acpRegistryAgents.size} clients=${_state.value.acpInstalledClients.size}",
        )
        _state.update { it.copy(acpRegistryLoading = true, acpRegistryError = null) }
        viewModelScope.launch {
            val sent = client.send(Payload.ACPRegistryRequest(payload), hex)
            Log.w(TAG, "acp registry request send id=${payload.clientRequestID} sent=$sent desktop=${hex.take(12)}")
            if (!sent) {
                if (pendingACPRegistryRequestID == payload.clientRequestID) pendingACPRegistryRequestID = null
                Log.w(TAG, "acp registry request failed to send id=${payload.clientRequestID}")
                _state.update { it.copy(acpRegistryLoading = false, acpRegistryError = "Failed to request agents.") }
                return@launch
            }
            delay(REMOTE_CONFIG_TIMEOUT_MS)
            if (pendingACPRegistryRequestID == payload.clientRequestID) {
                pendingACPRegistryRequestID = null
                Log.w(TAG, "acp registry request timed out id=${payload.clientRequestID}")
                if (retryOnTimeout) {
                    Log.w(TAG, "acp registry request retrying once after timeout id=${payload.clientRequestID}")
                    requestACPRegistry(forceRefresh = forceRefresh, retryOnTimeout = false)
                    return@launch
                }
                _state.update { it.copy(acpRegistryLoading = false, acpRegistryError = REMOTE_TIMEOUT_MESSAGE) }
            }
        }
    }

    fun installACPAgent(registryAgentID: String) =
        mutateACP(
            app.rxlab.rxcode.proto.ACPMutationRequestPayload.Operation.INSTALL,
            key = registryAgentID,
            registryAgentID = registryAgentID,
        )

    fun uninstallACPClient(clientID: String) =
        mutateACP(
            app.rxlab.rxcode.proto.ACPMutationRequestPayload.Operation.UNINSTALL,
            key = clientID,
            clientID = clientID,
        )

    fun setACPClientEnabled(clientID: String, enabled: Boolean) =
        mutateACP(
            app.rxlab.rxcode.proto.ACPMutationRequestPayload.Operation.SET_ENABLED,
            key = clientID,
            clientID = clientID,
            enabled = enabled,
        )

    private fun mutateACP(
        operation: app.rxlab.rxcode.proto.ACPMutationRequestPayload.Operation,
        key: String,
        registryAgentID: String? = null,
        clientID: String? = null,
        enabled: Boolean? = null,
    ) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) {
            _state.update { it.copy(lastACPError = "Connect a Mac first.") }
            return
        }
        if (_state.value.inFlightACPMutations.contains(key)) return
        val payload = app.rxlab.rxcode.proto.ACPMutationRequestPayload(
            operation = operation,
            registryAgentID = registryAgentID,
            clientID = clientID,
            enabled = enabled,
        )
        acpMutationKeys[payload.clientRequestID] = key
        _state.update { it.copy(inFlightACPMutations = it.inFlightACPMutations + key, lastACPError = null) }
        val timeout = if (operation == app.rxlab.rxcode.proto.ACPMutationRequestPayload.Operation.INSTALL) {
            ACP_INSTALL_TIMEOUT_MS
        } else {
            REMOTE_CONFIG_TIMEOUT_MS
        }
        viewModelScope.launch {
            val sent = client.send(Payload.ACPMutationRequest(payload), hex)
            if (!sent) {
                acpMutationKeys.remove(payload.clientRequestID)
                _state.update {
                    it.copy(
                        inFlightACPMutations = it.inFlightACPMutations - key,
                        lastACPError = "Failed to send request.",
                    )
                }
                return@launch
            }
            delay(timeout)
            if (acpMutationKeys.remove(payload.clientRequestID) != null) {
                _state.update {
                    it.copy(
                        inFlightACPMutations = it.inFlightACPMutations - key,
                        lastACPError = REMOTE_TIMEOUT_MESSAGE,
                    )
                }
            }
        }
    }

    private fun applyACPRegistryResult(result: app.rxlab.rxcode.proto.ACPRegistryResultPayload) {
        val pending = pendingACPRegistryRequestID
        if (pending != result.clientRequestID) {
            Log.w(
                TAG,
                "acp registry result dropped id=${result.clientRequestID} pending=$pending " +
                    "ok=${result.ok} agents=${result.registryAgents.size} clients=${result.installedClients.size}",
            )
            return
        }
        pendingACPRegistryRequestID = null
        Log.w(
            TAG,
            "acp registry result applied id=${result.clientRequestID} ok=${result.ok} " +
                "agents=${result.registryAgents.size} clients=${result.installedClients.size}",
        )
        _state.update {
            it.copy(
                acpRegistryLoading = false,
                acpRegistryAgents = if (result.ok) result.registryAgents else it.acpRegistryAgents,
                acpInstalledClients = if (result.ok) result.installedClients else it.acpInstalledClients,
                acpRegistryError = if (result.ok) null else (result.errorMessage ?: "Failed to load the agent registry."),
            )
        }
    }

    private fun applyACPMutationResult(result: app.rxlab.rxcode.proto.ACPMutationResultPayload) {
        val key = acpMutationKeys.remove(result.clientRequestID)
        _state.update {
            it.copy(
                inFlightACPMutations = if (key != null) it.inFlightACPMutations - key else it.inFlightACPMutations,
                acpRegistryAgents = result.registryAgents,
                acpInstalledClients = result.installedClients,
                lastACPError = if (result.ok) null else (result.errorMessage ?: "Agent operation failed."),
            )
        }
    }

    // ---- Skills marketplace ----

    fun requestSkillCatalog(forceRefresh: Boolean = false, retryOnTimeout: Boolean = true) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) {
            Log.w(TAG, "skill catalog request skipped: no active desktop")
            pendingSkillCatalogRequestID = null
            _state.update { it.copy(skillCatalogError = "Connect a Mac to browse skills.") }
            return
        }
        if (!_state.value.hasReceivedInitialSnapshot) {
            Log.w(TAG, "skill catalog request skipped: waiting for initial snapshot")
            pendingSkillCatalogRequestID = null
            _state.update { it.copy(skillCatalogLoading = false, skillCatalogError = null) }
            return
        }
        val payload = app.rxlab.rxcode.proto.SkillCatalogRequestPayload(forceRefresh = forceRefresh)
        pendingSkillCatalogRequestID = payload.clientRequestID
        Log.w(
            TAG,
            "skill catalog request start id=${payload.clientRequestID} forceRefresh=$forceRefresh " +
                "desktop=${hex.take(12)} connection=${_state.value.connectionState} " +
                "plugins=${_state.value.skillCatalog.size} sources=${_state.value.skillSources.size}",
        )
        _state.update { it.copy(skillCatalogLoading = true, skillCatalogError = null) }
        viewModelScope.launch {
            val sent = client.send(Payload.SkillCatalogRequest(payload), hex)
            Log.w(TAG, "skill catalog request send id=${payload.clientRequestID} sent=$sent desktop=${hex.take(12)}")
            if (!sent) {
                if (pendingSkillCatalogRequestID == payload.clientRequestID) pendingSkillCatalogRequestID = null
                Log.w(TAG, "skill catalog request failed to send id=${payload.clientRequestID}")
                _state.update { it.copy(skillCatalogLoading = false, skillCatalogError = "Failed to request skills.") }
                return@launch
            }
            delay(REMOTE_CONFIG_TIMEOUT_MS)
            if (pendingSkillCatalogRequestID == payload.clientRequestID) {
                pendingSkillCatalogRequestID = null
                Log.w(TAG, "skill catalog request timed out id=${payload.clientRequestID}")
                if (retryOnTimeout) {
                    Log.w(TAG, "skill catalog request retrying once after timeout id=${payload.clientRequestID}")
                    requestSkillCatalog(forceRefresh = forceRefresh, retryOnTimeout = false)
                    return@launch
                }
                _state.update { it.copy(skillCatalogLoading = false, skillCatalogError = REMOTE_TIMEOUT_MESSAGE) }
            }
        }
    }

    fun installSkill(pluginID: String) =
        mutateSkill(pluginID, app.rxlab.rxcode.proto.SkillMutationRequestPayload.Operation.INSTALL)

    fun uninstallSkill(pluginID: String) =
        mutateSkill(pluginID, app.rxlab.rxcode.proto.SkillMutationRequestPayload.Operation.UNINSTALL)

    private fun mutateSkill(
        pluginID: String,
        operation: app.rxlab.rxcode.proto.SkillMutationRequestPayload.Operation,
    ) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) {
            _state.update { it.copy(lastSkillError = "Connect a Mac first.") }
            return
        }
        if (_state.value.inFlightSkillMutations.contains(pluginID)) return
        val payload = app.rxlab.rxcode.proto.SkillMutationRequestPayload(operation = operation, pluginID = pluginID)
        _state.update {
            it.copy(inFlightSkillMutations = it.inFlightSkillMutations + pluginID, lastSkillError = null)
        }
        viewModelScope.launch {
            val sent = client.send(Payload.SkillMutationRequest(payload), hex)
            if (!sent) {
                _state.update {
                    it.copy(
                        inFlightSkillMutations = it.inFlightSkillMutations - pluginID,
                        lastSkillError = "Failed to send request.",
                    )
                }
                return@launch
            }
            delay(REMOTE_CONFIG_TIMEOUT_MS)
            if (_state.value.inFlightSkillMutations.contains(pluginID)) {
                _state.update {
                    it.copy(
                        inFlightSkillMutations = it.inFlightSkillMutations - pluginID,
                        lastSkillError = REMOTE_TIMEOUT_MESSAGE,
                    )
                }
            }
        }
    }

    /** Add a custom marketplace Git source; [ref] is an optional branch/tag. */
    fun addSkillGitSource(url: String, ref: String?) {
        val trimmedURL = url.trim()
        if (trimmedURL.isEmpty()) {
            _state.update { it.copy(lastSkillError = "Enter a GitHub repository URL.") }
            return
        }
        val trimmedRef = ref?.trim()?.takeIf { it.isNotEmpty() }
        mutateSkillSource(
            key = "add:$trimmedURL",
            operation = app.rxlab.rxcode.proto.SkillSourceMutationRequestPayload.Operation.ADD,
            gitURL = trimmedURL,
            ref = trimmedRef,
        )
    }

    fun removeSkillGitSource(sourceID: String) =
        mutateSkillSource(
            key = sourceID,
            operation = app.rxlab.rxcode.proto.SkillSourceMutationRequestPayload.Operation.REMOVE,
            sourceID = sourceID,
        )

    private fun mutateSkillSource(
        key: String,
        operation: app.rxlab.rxcode.proto.SkillSourceMutationRequestPayload.Operation,
        sourceID: String? = null,
        gitURL: String? = null,
        ref: String? = null,
    ) {
        val hex = _state.value.activeDesktopPubkey
        if (hex.isEmpty()) {
            _state.update { it.copy(lastSkillError = "Connect a Mac first.") }
            return
        }
        if (_state.value.inFlightSkillSourceMutations.contains(key)) return
        val payload = app.rxlab.rxcode.proto.SkillSourceMutationRequestPayload(
            operation = operation,
            sourceID = sourceID,
            gitURL = gitURL,
            ref = ref,
        )
        skillSourceMutationKeys[payload.clientRequestID] = key
        _state.update {
            it.copy(inFlightSkillSourceMutations = it.inFlightSkillSourceMutations + key, lastSkillError = null)
        }
        viewModelScope.launch {
            val sent = client.send(Payload.SkillSourceMutationRequest(payload), hex)
            if (!sent) {
                skillSourceMutationKeys.remove(payload.clientRequestID)
                _state.update {
                    it.copy(
                        inFlightSkillSourceMutations = it.inFlightSkillSourceMutations - key,
                        lastSkillError = "Failed to send request.",
                    )
                }
                return@launch
            }
            delay(REMOTE_CONFIG_TIMEOUT_MS)
            if (skillSourceMutationKeys.remove(payload.clientRequestID) != null) {
                _state.update {
                    it.copy(
                        inFlightSkillSourceMutations = it.inFlightSkillSourceMutations - key,
                        lastSkillError = REMOTE_TIMEOUT_MESSAGE,
                    )
                }
            }
        }
    }

    private fun applySkillCatalogResult(result: app.rxlab.rxcode.proto.SkillCatalogResultPayload) {
        val pending = pendingSkillCatalogRequestID
        if (pending != result.clientRequestID) {
            Log.w(
                TAG,
                "skill catalog result dropped id=${result.clientRequestID} pending=$pending " +
                    "ok=${result.ok} plugins=${result.plugins.size} sources=${result.sources.size}",
            )
            return
        }
        pendingSkillCatalogRequestID = null
        Log.w(
            TAG,
            "skill catalog result applied id=${result.clientRequestID} ok=${result.ok} " +
                "plugins=${result.plugins.size} sources=${result.sources.size}",
        )
        _state.update {
            it.copy(
                skillCatalogLoading = false,
                skillCatalog = if (result.ok) result.plugins else it.skillCatalog,
                skillSources = if (result.ok) result.sources else it.skillSources,
                skillCatalogError = if (result.ok) null else (result.errorMessage ?: "Failed to load skills."),
            )
        }
    }

    private fun applySkillMutationResult(result: app.rxlab.rxcode.proto.SkillMutationResultPayload) {
        _state.update {
            it.copy(
                inFlightSkillMutations = it.inFlightSkillMutations - result.pluginID,
                skillCatalog = result.plugins,
                skillSources = result.sources,
                lastSkillError = if (result.ok) null else (result.errorMessage ?: "Skill operation failed."),
            )
        }
    }

    private fun applySkillSourceMutationResult(result: app.rxlab.rxcode.proto.SkillSourceMutationResultPayload) {
        val key = skillSourceMutationKeys.remove(result.clientRequestID)
        _state.update {
            var next = it.inFlightSkillSourceMutations
            if (key != null) next = next - key
            if (result.sourceID != null) next = next - result.sourceID
            it.copy(
                inFlightSkillSourceMutations = next,
                skillCatalog = result.plugins,
                skillSources = result.sources,
                lastSkillError = if (result.ok) null else (result.errorMessage ?: "Skill source operation failed."),
            )
        }
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
        pendingACPRegistryRequestID = null
        pendingSkillCatalogRequestID = null
        _state.update {
            it.copy(
                pairing = PairingStatus.InProgress,
                hasReceivedInitialSnapshot = false,
                acpRegistryLoading = false,
                skillCatalogLoading = false,
                acpRegistryError = null,
                skillCatalogError = null,
            )
        }
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
        autopilot.cancelAll("The paired Mac changed before the request finished.")
        secrets.clearKek()
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
        autopilot.cancelAll("This device is no longer paired with that Mac.")
        secrets.clearKek()
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
        private const val SEARCH_DEBOUNCE_MS = 200L
        private const val SEARCH_LIMIT = 25

        // Remote-config (MCP/ACP/Skills) timeouts, mirroring iOS: ACP installs
        // download a binary, so they get a much longer ceiling.
        private const val REMOTE_CONFIG_TIMEOUT_MS = 20_000L
        private const val ACP_INSTALL_TIMEOUT_MS = 90_000L
        private const val REMOTE_TIMEOUT_MESSAGE = "Request timed out. Check your Mac and try again."

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
