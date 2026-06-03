package app.rxlab.rxcode.store

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Regression tests for relay-aware unpair matching. The bug: when the same Mac
 * was paired through two relays, an inbound unpair matched by pubkey alone and
 * removed the *other* relay's entry. [PairedDesktop.matchForUnpair] must resolve
 * the entry for the relay the unpair actually arrived on.
 */
class PairedDesktopUnpairTest {

    private fun desktop(pubkey: String, relay: String?) =
        PairedDesktop(pubkeyHex = pubkey, displayName = "Mac", pairedAtEpochMs = 0L, relayUrl = relay)

    @Test
    fun picksEntryForArrivingRelay() {
        val a = desktop("PUB", "wss://relay1.example.com/ws")
        val b = desktop("PUB", "wss://relay2.example.com/ws")

        val match = PairedDesktop.matchForUnpair(listOf(a, b), "PUB", "wss://relay2.example.com/ws")

        assertEquals(b.id, match?.id)
    }

    @Test
    fun normalizesRelayBeforeMatching() {
        val a = desktop("PUB", "wss://relay1.example.com/ws")
        val b = desktop("PUB", "wss://relay2.example.com/ws")

        val match = PairedDesktop.matchForUnpair(listOf(a, b), "PUB", "WSS://Relay2.Example.com/ws/")

        assertEquals(b.id, match?.id)
    }

    @Test
    fun singleEntryFallbackForLegacyPairing() {
        val legacy = desktop("PUB", null)

        val match = PairedDesktop.matchForUnpair(listOf(legacy), "PUB", "wss://relay1.example.com/ws")

        assertEquals(legacy.id, match?.id)
    }

    @Test
    fun ambiguousRelayDoesNotGuess() {
        val a = desktop("PUB", "wss://relay1.example.com/ws")
        val b = desktop("PUB", "wss://relay2.example.com/ws")

        val match = PairedDesktop.matchForUnpair(listOf(a, b), "PUB", "wss://relay3.example.com/ws")

        assertNull(match)
    }

    @Test
    fun ignoresOtherMacs() {
        val mine = desktop("PUB", "wss://relay1.example.com/ws")
        val other = desktop("OTHER", "wss://relay1.example.com/ws")

        val match = PairedDesktop.matchForUnpair(listOf(mine, other), "PUB", "wss://relay1.example.com/ws")

        assertEquals(mine.id, match?.id)
    }

    @Test
    fun noMatchForUnknownPubkey() {
        val a = desktop("PUB", "wss://relay1.example.com/ws")

        val match = PairedDesktop.matchForUnpair(listOf(a), "NOPE", "wss://relay1.example.com/ws")

        assertNull(match)
    }
}
