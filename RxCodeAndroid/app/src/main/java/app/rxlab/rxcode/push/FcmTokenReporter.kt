package app.rxlab.rxcode.push

import android.util.Log
import app.rxlab.rxcode.proto.Payload
import app.rxlab.rxcode.proto.PushTokenPayload
import app.rxlab.rxcode.relay.RelayClient
import app.rxlab.rxcode.store.PairingStore
import app.rxlab.rxcode.sync.SyncClient
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

@Singleton
class FcmTokenReporter @Inject constructor(
    private val store: PairingStore,
    private val client: SyncClient,
) {
    suspend fun report(token: String) {
        if (token.isBlank()) return
        val desktops = store.pairedDesktops.first()
        if (desktops.isEmpty()) {
            Log.w(TAG, "FCM token report skipped: no paired desktops")
            return
        }

        for (desktop in desktops) {
            desktop.relayUrl?.let { client.setRelayUrl(it) }
            client.addPeer(desktop.pubkeyHex)
            client.start()
            withTimeoutOrNull(CONNECT_TIMEOUT_MS) {
                client.connectionState.first { it == RelayClient.ConnectionState.CONNECTED }
            }
            val sent = client.send(
                Payload.PushToken(PushTokenPayload(provider = "fcm", token = token)),
                desktop.pubkeyHex,
            )
            Log.w(
                TAG,
                "FCM token report sent=$sent desktop=${desktop.pubkeyHex.take(12)} token=${token.take(12)}",
            )
        }
    }

    private companion object {
        private const val TAG = "FcmTokenReporter"
        private const val CONNECT_TIMEOUT_MS = 5_000L
    }
}
