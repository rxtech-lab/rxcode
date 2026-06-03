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
        get() = compositeId(pubkeyHex, relayUrl)

    companion object {
        /** Normalize a relay URL for comparison (trim whitespace/slashes, lowercase). */
        fun normalizeRelay(relayUrl: String?): String =
            (relayUrl ?: "").trim().lowercase().trim('/')

        /** Build the composite id (pubkey + normalized relay) without an instance. */
        fun compositeId(pubkeyHex: String, relayUrl: String?): String =
            "$pubkeyHex::${normalizeRelay(relayUrl)}"

        /**
         * Selects the pairing an inbound unpair targets. The unpair arrives over
         * the relay this client is currently connected to, so it identifies the
         * entry for that specific relay — matching by pubkey alone would remove an
         * entry for the same Mac on a *different* relay. Falls back to the sole
         * pairing for a Mac when there is only one (covers legacy entries that
         * predate stored relay URLs), and returns null when the choice is
         * ambiguous so we never remove the wrong relay's entry.
         */
        fun matchForUnpair(
            desktops: List<PairedDesktop>,
            fromHex: String,
            currentRelay: String?,
        ): PairedDesktop? {
            val samePubkey = desktops.filter { it.pubkeyHex == fromHex }
            val targetId = compositeId(fromHex, currentRelay)
            return samePubkey.firstOrNull { it.id == targetId } ?: samePubkey.singleOrNull()
        }
    }
}
