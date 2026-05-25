package app.rxlab.rxcode.push

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Base64
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import app.rxlab.rxcode.MainActivity
import app.rxlab.rxcode.R
import app.rxlab.rxcode.crypto.Hex
import app.rxlab.rxcode.crypto.SessionCrypto
import app.rxlab.rxcode.identity.DeviceIdentity
import app.rxlab.rxcode.proto.RxJson
import app.rxlab.rxcode.store.PairingStore
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import org.bouncycastle.crypto.params.X25519PublicKeyParameters

@AndroidEntryPoint
class RxCodeFirebaseMessagingService : FirebaseMessagingService() {
    @Inject lateinit var identity: DeviceIdentity
    @Inject lateinit var store: PairingStore
    @Inject lateinit var tokenReporter: FcmTokenReporter

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onNewToken(token: String) {
        Log.w(TAG, "FCM token refreshed token=${token.take(12)}")
        scope.launch { tokenReporter.report(token) }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val encrypted = message.data["enc"] ?: message.data["encrypted_alert"]
        if (encrypted.isNullOrBlank()) {
            Log.w(TAG, "FCM message ignored: missing encrypted alert")
            return
        }
        scope.launch {
            runCatching { decryptAlert(encrypted) }
                .onSuccess { showNotification(it) }
                .onFailure { Log.w(TAG, "FCM alert decrypt failed: ${it.message}", it) }
        }
    }

    private suspend fun decryptAlert(encryptedAlertBase64: String): AlertPlaintext {
        val envelopeJSON = Base64.decode(encryptedAlertBase64, Base64.DEFAULT)
            .toString(Charsets.UTF_8)
        val envelope = RxJson.decodeFromString(EncryptedAlert.serializer(), envelopeJSON)
        val desktop = store.pairedDesktops.first()
            .firstOrNull { it.pubkeyHex.equals(envelope.from, ignoreCase = true) }
            ?: error("unknown sender ${envelope.from.take(12)}")
        val senderBytes = Hex.decode(desktop.pubkeyHex)
            ?: error("invalid sender key ${desktop.pubkeyHex.take(12)}")
        val nonce = Base64.decode(envelope.nonce, Base64.DEFAULT)
        val ciphertext = Base64.decode(envelope.ct, Base64.DEFAULT)
        val plaintext = SessionCrypto.open(
            ciphertext,
            nonce,
            identity.privateKey,
            X25519PublicKeyParameters(senderBytes, 0),
        )
        return RxJson.decodeFromString(AlertPlaintext.serializer(), plaintext.toString(Charsets.UTF_8))
    }

    @SuppressLint("MissingPermission")
    private fun showNotification(alert: AlertPlaintext) {
        ensureChannel()
        val notifID = notificationID(alert)
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            alert.sessionID?.takeIf { it.isNotBlank() }?.let { putExtra(EXTRA_SESSION_ID, it) }
            alert.projectID?.takeIf { it.isNotBlank() }?.let { putExtra(EXTRA_PROJECT_ID, it) }
        }
        // Use the per-alert notif id as the request code so notifications for
        // different threads each get their own PendingIntent (and don't share
        // extras via FLAG_UPDATE_CURRENT).
        val pendingIntent = PendingIntent.getActivity(
            this,
            notifID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(alert.title)
            .setContentText(alert.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(alert.body))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        try {
            NotificationManagerCompat.from(this).notify(notifID, notification)
        } catch (security: SecurityException) {
            Log.w(TAG, "notification permission missing; dropping FCM alert")
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.app_name),
                NotificationManager.IMPORTANCE_HIGH,
            )
        )
    }

    private fun notificationID(alert: AlertPlaintext): Int =
        (alert.sessionID ?: alert.projectID ?: alert.kind ?: alert.title).hashCode()

    companion object {
        const val EXTRA_SESSION_ID = "app.rxlab.rxcode.extra.SESSION_ID"
        const val EXTRA_PROJECT_ID = "app.rxlab.rxcode.extra.PROJECT_ID"
        private const val TAG = "RxCodeFCM"
        private const val CHANNEL_ID = "rxcode_notifications"
    }
}
