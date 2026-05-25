package app.rxlab.rxcode.relay

import android.util.Log
import app.rxlab.rxcode.identity.DeviceIdentity
import app.rxlab.rxcode.proto.Envelope
import app.rxlab.rxcode.proto.RxJson
import app.rxlab.rxcode.proto.envelopeOrDeliveryFailure
import app.rxlab.rxcode.proto.EnvelopeOrFailure
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.math.pow

/**
 * Single WebSocket to the relay, keyed by the mobile pubkey. The relay sees only
 * [Envelope] frames — payload encryption lives one layer up in `SyncClient`.
 *
 * Behavioural parity with Swift's `RelayClient`:
 *  - reconnect with exponential backoff capped at 30s;
 *  - 25s app-level ping keepalive;
 *  - failures from the receive loop and the ping handler only schedule one
 *    reconnect, so we don't stack sockets on the same pubkey.
 */
class RelayClient(
    private val identity: DeviceIdentity,
    relayUrl: String,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING }

    sealed interface Event {
        data class Inbound(val fromHex: String, val envelope: Envelope) : Event
        data class DeliveryFailed(val toHex: String) : Event
        data class StateChanged(val state: ConnectionState) : Event
    }

    private val mutex = Mutex()
    private val client = OkHttpClient.Builder()
        .pingInterval(25, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 64)
    val events: SharedFlow<Event> = _events.asSharedFlow()

    @Volatile private var socket: WebSocket? = null
    @Volatile private var shouldReconnect = false
    @Volatile private var reconnectAttempt = 0
    @Volatile private var reconnectJob: Job? = null
    @Volatile private var relayUrl: String = relayUrl

    suspend fun setRelayUrl(url: String) = mutex.withLock {
        if (this.relayUrl == url) return@withLock
        this.relayUrl = url
        if (socket != null) {
            closeLocally()
            openLocked()
        }
    }

    suspend fun connect() = mutex.withLock {
        shouldReconnect = true
        if (socket == null) openLocked()
    }

    suspend fun disconnect() = mutex.withLock {
        shouldReconnect = false
        closeLocally()
        updateState(ConnectionState.DISCONNECTED)
    }

    /** Send a pre-encrypted envelope JSON to the relay. */
    suspend fun sendEnvelope(envelope: Envelope): Boolean {
        val ws = socket ?: return false
        val raw = RxJson.encodeToString(Envelope.serializer(), envelope)
        return ws.send(raw)
    }

    private fun openLocked() {
        if (!shouldReconnect) return
        if (socket != null) return
        updateState(ConnectionState.CONNECTING)
        val urlWithKey = buildWsUrl(relayUrl, identity.publicKeyHex) ?: run {
            Log.e(TAG, "invalid relay URL: $relayUrl")
            scheduleReconnect()
            return
        }
        val req = Request.Builder().url(urlWithKey).build()
        socket = client.newWebSocket(req, listener)
    }

    private fun closeLocally() {
        reconnectJob?.cancel()
        reconnectJob = null
        socket?.cancel()
        socket = null
    }

    private fun updateState(next: ConnectionState) {
        if (_state.value == next) return
        _state.value = next
        _events.tryEmit(Event.StateChanged(next))
    }

    private fun scheduleReconnect() {
        if (!shouldReconnect) return
        reconnectAttempt += 1
        val delaySeconds = min(30, 2.0.pow(reconnectAttempt.toDouble()).toInt())
        updateState(ConnectionState.RECONNECTING)
        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(delaySeconds * 1000L)
            mutex.withLock { openLocked() }
        }
    }

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            reconnectAttempt = 0
            updateState(ConnectionState.CONNECTED)
        }

        override fun onMessage(webSocket: WebSocket, text: String) = handleRaw(text)

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) =
            handleRaw(bytes.utf8())

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            if (webSocket !== socket) return
            socket = null
            scope.launch { mutex.withLock { scheduleReconnect() } }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            if (webSocket !== socket) return
            Log.w(TAG, "websocket failed: ${t.message}")
            socket = null
            scope.launch { mutex.withLock { scheduleReconnect() } }
        }
    }

    private fun handleRaw(raw: String) {
        when (val parsed = envelopeOrDeliveryFailure(raw)) {
            is EnvelopeOrFailure.Env -> _events.tryEmit(
                Event.Inbound(parsed.envelope.from, parsed.envelope)
            )
            is EnvelopeOrFailure.Failure -> _events.tryEmit(
                Event.DeliveryFailed(parsed.notice.to)
            )
            null -> Log.w(TAG, "dropping non-envelope frame (${raw.length} chars)")
        }
    }

    companion object {
        private const val TAG = "RelayClient"

        internal fun buildWsUrl(base: String, pubkeyHex: String): String? {
            val trimmed = base.trimEnd('/')
            val withWs = if (trimmed.endsWith("/ws", ignoreCase = true)) trimmed else "$trimmed/ws"
            val sep = if (withWs.contains('?')) '&' else '?'
            // Validate scheme.
            if (!withWs.startsWith("ws://", true) && !withWs.startsWith("wss://", true)) return null
            return "$withWs${sep}pubkey=$pubkeyHex"
        }
    }
}
