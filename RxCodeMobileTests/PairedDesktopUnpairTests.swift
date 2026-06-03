import XCTest
@testable import RxCodeMobile

/// Regression tests for the relay-aware unpair matching. The bug: when the same
/// Mac was paired through two relays, an inbound unpair matched by pubkey alone
/// and removed the *other* relay's entry. `matchForUnpair` must resolve the entry
/// for the relay the unpair actually arrived on.
final class PairedDesktopUnpairTests: XCTestCase {

    private func desktop(_ pubkey: String, relay: String?) -> PairedDesktop {
        PairedDesktop(pubkeyHex: pubkey, displayName: "Mac", pairedAt: .init(timeIntervalSince1970: 0), lastSeen: nil, relayURL: relay)
    }

    func testPicksEntryForArrivingRelay() {
        let a = desktop("PUB", relay: "wss://relay1.example.com/ws")
        let b = desktop("PUB", relay: "wss://relay2.example.com/ws")

        let match = PairedDesktop.matchForUnpair(in: [a, b], fromHex: "PUB", currentRelay: "wss://relay2.example.com/ws")

        XCTAssertEqual(match?.id, b.id, "Unpair over relay2 must remove the relay2 entry, not relay1.")
    }

    func testNormalizesRelayBeforeMatching() {
        let a = desktop("PUB", relay: "wss://relay1.example.com/ws")
        let b = desktop("PUB", relay: "wss://relay2.example.com/ws")

        // Trailing slash + different casing must still resolve to relay2.
        let match = PairedDesktop.matchForUnpair(in: [a, b], fromHex: "PUB", currentRelay: "WSS://Relay2.Example.com/ws/")

        XCTAssertEqual(match?.id, b.id)
    }

    func testSingleEntryFallbackForLegacyPairing() {
        // Legacy entry with no stored relay URL; unpair should still resolve it
        // since there is exactly one pairing for this Mac.
        let legacy = desktop("PUB", relay: nil)

        let match = PairedDesktop.matchForUnpair(in: [legacy], fromHex: "PUB", currentRelay: "wss://relay1.example.com/ws")

        XCTAssertEqual(match?.id, legacy.id)
    }

    func testAmbiguousRelayDoesNotGuess() {
        // Two relays, but the unpair arrived on a relay matching neither entry.
        // Removing either would be a guess, so match nothing.
        let a = desktop("PUB", relay: "wss://relay1.example.com/ws")
        let b = desktop("PUB", relay: "wss://relay2.example.com/ws")

        let match = PairedDesktop.matchForUnpair(in: [a, b], fromHex: "PUB", currentRelay: "wss://relay3.example.com/ws")

        XCTAssertNil(match, "An unpair from an unknown relay must not remove an arbitrary entry.")
    }

    func testIgnoresOtherMacs() {
        let mine = desktop("PUB", relay: "wss://relay1.example.com/ws")
        let other = desktop("OTHER", relay: "wss://relay1.example.com/ws")

        let match = PairedDesktop.matchForUnpair(in: [mine, other], fromHex: "PUB", currentRelay: "wss://relay1.example.com/ws")

        XCTAssertEqual(match?.id, mine.id)
    }

    func testNoMatchForUnknownPubkey() {
        let a = desktop("PUB", relay: "wss://relay1.example.com/ws")

        let match = PairedDesktop.matchForUnpair(in: [a], fromHex: "NOPE", currentRelay: "wss://relay1.example.com/ws")

        XCTAssertNil(match)
    }
}
