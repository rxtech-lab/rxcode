import Foundation
import CryptoKit
import Testing
@testable import RxCodeSync

/// Covers the P2P wire additions: the ICE signaling payloads and the shared
/// `EnvelopeCodec` that both `RelayClient` and `DirectTransport` use, so a direct
/// link carries exactly the same E2E-sealed bytes as the relay.
@Suite("Direct transport wire format")
struct DirectTransportCodecTests {
    @Test("ice candidates payload round trips through Payload")
    func iceCandidatesRoundTrip() throws {
        let sid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let payload = Payload.iceCandidates(
            ICECandidatesPayload(
                sessionID: sid,
                candidates: [
                    ICECandidate(kind: .lanBonjour, host: "", port: 0, bonjourName: "RxCode-Mac"),
                    ICECandidate(kind: .lanInterface, host: "192.168.1.20", port: 51234),
                ],
                observedPublicIP: "203.0.113.7"
            )
        )
        let data = try JSONEncoder().encode(payload)
        guard case .iceCandidates(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected iceCandidates payload"); return
        }
        #expect(decoded.sessionID == sid)
        #expect(decoded.candidates.count == 2)
        #expect(decoded.candidates.first?.bonjourName == "RxCode-Mac")
        #expect(decoded.observedPublicIP == "203.0.113.7")
    }

    @Test("ice selected handshake payload round trips")
    func iceSelectedRoundTrip() throws {
        let sid = UUID()
        let data = try JSONEncoder().encode(Payload.iceSelected(ICESelectedPayload(sessionID: sid, echo: true)))
        guard case .iceSelected(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected iceSelected payload"); return
        }
        #expect(decoded.sessionID == sid)
        #expect(decoded.echo == true)
    }

    @Test("older peers decode the new ICE types as unknown, not a decode failure")
    func iceTypesAreForwardCompatible() throws {
        // Simulates a build that predates the ICE cases receiving one.
        let json = #"{"type":"ice_selected","data":{"sessionID":"11111111-2222-3333-4444-555555555555","echo":false}}"#
        // Re-encode via a raw type the enum doesn't know by mangling the tag.
        let unknownJSON = json.replacingOccurrences(of: "ice_selected", with: "some_future_type")
        let decoded = try JSONDecoder().decode(Payload.self, from: Data(unknownJSON.utf8))
        guard case .unknown(let type) = decoded else {
            Issue.record("Expected unknown payload"); return
        }
        #expect(type == "some_future_type")
    }

    @Test("EnvelopeCodec seals for the recipient and opens on the other side")
    func envelopeCodecRoundTrip() throws {
        // Two independent device identities (as desktop + mobile would have).
        let alice = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let bob = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())

        let payload = Payload.iceSelected(ICESelectedPayload(sessionID: UUID(), echo: false))
        let wire = try EnvelopeCodec.encode(payload, from: alice, to: bob.publicKey)

        // Bob decodes: gets the payload, attributed to Alice.
        guard case .inbound(let inbound) = EnvelopeCodec.decode(wire, localIdentity: bob) else {
            Issue.record("Bob should decode Alice's envelope"); return
        }
        #expect(inbound.fromHex == alice.publicKeyHex)
        guard case .iceSelected = inbound.payload else {
            Issue.record("Expected iceSelected inbound"); return
        }

        // A third party (not the recipient) cannot open it — dropped, not crashed.
        let eve = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        if case .inbound = EnvelopeCodec.decode(wire, localIdentity: eve) {
            Issue.record("Eve must not be able to open an envelope addressed to Bob")
        }
    }

    @Test("interface enumeration excludes loopback and link-local")
    func interfaceCandidatesAreRoutable() {
        // Whatever this host reports, the filter must never surface loopback or
        // link-local addresses (they can't reach a peer).
        for ip in NetworkInterfaces.localIPAddresses() {
            #expect(ip != "127.0.0.1")
            #expect(ip != "::1")
            #expect(!ip.hasPrefix("169.254."))
            #expect(!ip.lowercased().hasPrefix("fe80:"))
            #expect(!ip.contains("%"))
        }
    }

    @Test("wan-mapped candidate round trips through Payload")
    func wanMappedCandidateRoundTrip() throws {
        let payload = Payload.iceCandidates(
            ICECandidatesPayload(
                sessionID: UUID(),
                candidates: [ICECandidate(kind: .wanMapped, host: "203.0.113.9", port: 40001)],
                observedPublicIP: "203.0.113.9"
            )
        )
        let data = try JSONEncoder().encode(payload)
        guard case .iceCandidates(let decoded) = try JSONDecoder().decode(Payload.self, from: data) else {
            Issue.record("Expected iceCandidates payload"); return
        }
        #expect(decoded.candidates.first?.kind == .wanMapped)
        #expect(decoded.candidates.first?.port == 40001)
    }

    @Test("EnvelopeCodec surfaces a delivery-failed notice")
    func envelopeCodecDeliveryFailed() throws {
        let me = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let notice = try JSONEncoder().encode(DeliveryFailedNotice(v: 1, type: "delivery_failed", to: "abcdef"))
        guard case .deliveryFailed(let toHex) = EnvelopeCodec.decode(notice, localIdentity: me) else {
            Issue.record("Expected delivery-failed result"); return
        }
        #expect(toHex == "abcdef")
    }
}
