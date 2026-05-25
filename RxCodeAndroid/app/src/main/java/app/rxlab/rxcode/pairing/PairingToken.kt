package app.rxlab.rxcode.pairing

import android.net.Uri
import app.rxlab.rxcode.proto.RxJson
import app.rxlab.rxcode.proto.SwiftDateSerializer
import app.rxlab.rxcode.proto.UuidSerializer
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.Base64
import java.util.UUID

/**
 * QR-code payload the desktop generates and the mobile scans. Wire-compatible
 * with Swift's `PairingToken` (base64-JSON, ISO-style Cocoa epoch dates).
 */
@Serializable
data class PairingToken(
    val v: Int = 1,
    val relayURL: String,
    val desktopPubkeyHex: String,
    @Serializable(with = UuidSerializer::class) val sessionID: UUID,
    val oneTimeSecretHex: String,
    @Serializable(with = SwiftDateSerializer::class) val issuedAt: Instant,
    @Serializable(with = SwiftDateSerializer::class) val expiresAt: Instant,
    val desktopName: String,
) {
    val isExpired: Boolean get() = Instant.now().isAfter(expiresAt)

    companion object {
        const val DEEPLINK_HOST = "code.rxlab.app"
        const val DEEPLINK_PATH = "/pair"
        const val LEGACY_SCHEME_PREFIX = "rxcode-pair:"

        /**
         * Parse either the modern `https://code.rxlab.app/pair?token=...` or the
         * legacy `rxcode-pair:<base64>` form. Returns null on a malformed input.
         */
        fun parseOrNull(input: String): PairingToken? {
            val trimmed = input.trim()
            val b64 = when {
                trimmed.startsWith(LEGACY_SCHEME_PREFIX) ->
                    trimmed.removePrefix(LEGACY_SCHEME_PREFIX)
                else -> tokenFromDeeplink(trimmed) ?: return null
            }
            return runCatching {
                val raw = Base64.getDecoder().decode(b64)
                RxJson.decodeFromString(serializer(), String(raw, Charsets.UTF_8))
            }.getOrNull()
        }

        private fun tokenFromDeeplink(input: String): String? {
            val uri = runCatching { Uri.parse(input) }.getOrNull() ?: return null
            if (!uri.scheme.equals("https", true)) return null
            if (!uri.host.equals(DEEPLINK_HOST, true)) return null
            if (uri.path != DEEPLINK_PATH) return null
            return uri.getQueryParameter("token")
        }
    }
}
