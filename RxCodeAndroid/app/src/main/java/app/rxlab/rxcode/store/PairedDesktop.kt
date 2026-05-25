package app.rxlab.rxcode.store

import kotlinx.serialization.Serializable

/**
 * One Mac the user has paired with. The `(pubkeyHex, relayUrl)` pair identifies
 * the pairing, since the same desktop reached through different relays must be
 * tracked as distinct entries (matches iOS `PairedDesktop`).
 */
@Serializable
data class PairedDesktop(
    val pubkeyHex: String,
    val displayName: String,
    val pairedAtEpochMs: Long,
    val lastSeenEpochMs: Long? = null,
    val relayUrl: String? = null,
) {
    val id: String
        get() {
            val normRelay = (relayUrl ?: "")
                .trim()
                .lowercase()
                .trim('/')
            return "$pubkeyHex::$normRelay"
        }
}
