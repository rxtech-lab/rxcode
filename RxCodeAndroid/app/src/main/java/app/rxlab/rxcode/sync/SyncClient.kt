package app.rxlab.rxcode.sync

import android.util.Log
import app.rxlab.rxcode.crypto.Hex
import app.rxlab.rxcode.crypto.SessionCrypto
import app.rxlab.rxcode.identity.DeviceIdentity
import app.rxlab.rxcode.proto.Envelope
import app.rxlab.rxcode.proto.Payload
import app.rxlab.rxcode.proto.RxJson
import app.rxlab.rxcode.relay.RelayClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.util.concurrent.ConcurrentHashMap

/**
 * High-level facade over [RelayClient]. Owns the peer key cache and translates
 * app intents into encrypted [Payload] envelopes.
 *
 * One mobile client typically has exactly one paired desktop, but the desktop
 * keeps the same shape so the same code can later support multi-mac pairing.
 */
class SyncClient(
    val identity: DeviceIdentity,
    relayUrl: String,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    sealed interface Event {
        data class Inbound(val fromHex: String, val payload: Payload) : Event
        data class DeliveryFailed(val toHex: String) : Event
        data class StateChanged(val state: RelayClient.ConnectionState) : Event
    }

    private val relay = RelayClient(identity, relayUrl, scope)
    private val peers = ConcurrentHashMap<String, X25519PublicKeyParameters>()

    private val _events = MutableSharedFlow<Event>(extraBufferCapacity = 128)
    val events: SharedFlow<Event> = _events.asSharedFlow()

    val connectionState: StateFlow<RelayClient.ConnectionState> get() = relay.state

    init {
        scope.launch {
            relay.events.collect { ev ->
                when (ev) {
                    is RelayClient.Event.StateChanged -> _events.emit(Event.StateChanged(ev.state))
                    is RelayClient.Event.DeliveryFailed -> _events.emit(Event.DeliveryFailed(ev.toHex))
                    is RelayClient.Event.Inbound -> handleEnvelope(ev.envelope)
                }
            }
        }
    }

    fun addPeer(pubkeyHex: String) {
        val raw = Hex.decode(pubkeyHex) ?: run {
            Log.w(TAG, "ignoring invalid peer hex: $pubkeyHex")
            return
        }
        peers[pubkeyHex] = X25519PublicKeyParameters(raw, 0)
    }

    fun removePeer(pubkeyHex: String) {
        peers.remove(pubkeyHex)
    }

    suspend fun setRelayUrl(url: String) = relay.setRelayUrl(url)

    suspend fun start() = relay.connect()

    suspend fun stop() = relay.disconnect()

    /** Encrypt and send `payload` to one paired peer. Returns true on enqueue. */
    suspend fun send(payload: Payload, toHex: String): Boolean {
        val recipient = peers[toHex] ?: run {
            Log.w(TAG, "send to unknown peer ${toHex.take(12)}")
            return false
        }
        val plaintext = RxJson.encodeToString(Payload.serializer(), payload).toByteArray(Charsets.UTF_8)
        val sealed = SessionCrypto.seal(plaintext, identity.privateKey, recipient)
        val envelope = Envelope.build(
            toHex = toHex,
            fromHex = identity.publicKeyHex,
            nonce = sealed.nonce,
            ciphertext = sealed.ciphertext,
        )
        return relay.sendEnvelope(envelope)
    }

    private suspend fun handleEnvelope(env: Envelope) {
        val nonce = env.nonceData ?: return
        val ct = env.ciphertextData ?: return
        val sender = peers[env.from] ?: run {
            // The pair_ack arrives before addPeer fires, so accept the
            // sender-supplied key on first contact and cache it for replays.
            val raw = Hex.decode(env.from) ?: return
            X25519PublicKeyParameters(raw, 0).also { peers[env.from] = it }
        }
        val plaintext = try {
            SessionCrypto.open(ct, nonce, identity.privateKey, sender)
        } catch (t: Throwable) {
            Log.w(TAG, "decrypt failed from ${env.from.take(12)}: ${t.message}")
            return
        }
        val payload = try {
            RxJson.decodeFromString(Payload.serializer(), String(plaintext, Charsets.UTF_8))
        } catch (t: Throwable) {
            Log.w(TAG, "decode failed from ${env.from.take(12)}: ${t.message}")
            return
        }
        _events.emit(Event.Inbound(env.from, payload))
    }

    companion object {
        private const val TAG = "SyncClient"
    }
}
