import CryptoKit
import Foundation
import Network
import Testing
@testable import RxCodeSync

private actor RecoveryHost: PeerManagerHost {
    func dial(_ endpoint: NWEndpoint, priority: Int, pathKind: ConnectionPathKind, for manager: PeerConnectionManager) async {}
    func localDirectCandidates() async -> [ICECandidate] { [] }
}

/// Counts how often the manager gathers candidates to offer them.
private actor OfferCountingHost: PeerManagerHost {
    private(set) var offerCount = 0
    func dial(_ endpoint: NWEndpoint, priority: Int, pathKind: ConnectionPathKind, for manager: PeerConnectionManager) async {}
    func localDirectCandidates() async -> [ICECandidate] {
        offerCount += 1
        return [ICECandidate(kind: .lanInterface, host: "192.168.1.2", port: 4000)]
    }
}

@Suite("Peer connection recovery")
struct PeerConnectionRecoveryTests {
    @Test("A peer offer is answered with our candidates once per peer session")
    func offerAnsweredOncePerSession() async throws {
        let local = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let remote = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(hexString: remote.publicKeyHex)!)
        let relay = RelayClient(identity: local, relayURL: URL(string: "ws://localhost:1")!)
        let host = OfferCountingHost()
        let manager = PeerConnectionManager(peerHex: remote.publicKeyHex, peerKey: key, identity: local, relay: relay, host: host)

        let session = UUID()
        let offer = Payload.iceCandidates(ICECandidatesPayload(sessionID: session, candidates: []))
        await manager.handleRelayICE(offer)
        await manager.handleRelayICE(offer)
        #expect(await host.offerCount == 1)

        // A new peer session (e.g. it changed networks) is answered again.
        await manager.handleRelayICE(.iceCandidates(ICECandidatesPayload(sessionID: UUID(), candidates: [])))
        #expect(await host.offerCount == 2)
        await manager.teardown()
    }

    @Test("Network change drops LAN and ignores late handshake from old probe")
    func networkChangeDropsStaleLAN() async throws {
        let local = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let remote = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(hexString: remote.publicKeyHex)!)
        let relay = RelayClient(identity: local, relayURL: URL(string: "ws://localhost:1")!)
        let host = RecoveryHost()
        let manager = PeerConnectionManager(peerHex: remote.publicKeyHex, peerKey: key, identity: local, relay: relay, host: host)
        let transport = DirectTransport(outboundTo: .hostPort(host: "127.0.0.1", port: 1), identity: local, expectedPeer: key)
        let handshake = TransportEvent.inbound(TransportInbound(
            from: key, fromHex: remote.publicKeyHex,
            payload: .iceSelected(ICESelectedPayload(sessionID: UUID(), echo: true))
        ))
        await manager.registerProbe(transport, pathKind: .directLAN)
        await manager.handleDirectEvent(handshake, from: transport)
        #expect(await manager.currentPath == .directLAN)
        await manager.networkChanged()
        #expect(await manager.currentPath == .relay)
        await manager.handleDirectEvent(handshake, from: transport)
        #expect(await manager.currentPath == .relay)
        await manager.teardown()
    }

    @Test("Path change events fire only on real transitions")
    func pathChangedOnlyOnTransitions() async throws {
        let local = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let remote = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(hexString: remote.publicKeyHex)!)
        let relay = RelayClient(identity: local, relayURL: URL(string: "ws://localhost:1")!)
        let manager = PeerConnectionManager(peerHex: remote.publicKeyHex, peerKey: key, identity: local, relay: relay, host: RecoveryHost())
        let events = await manager.events()

        // Already on the relay: repeated network changes must stay silent,
        // otherwise every NWPathMonitor callback triggers a full re-sync.
        await manager.networkChanged()
        await manager.networkChanged()

        let transport = DirectTransport(outboundTo: .hostPort(host: "127.0.0.1", port: 1), identity: local, expectedPeer: key)
        await manager.registerProbe(transport, pathKind: .directLAN)
        await manager.handleDirectEvent(.inbound(TransportInbound(
            from: key, fromHex: remote.publicKeyHex,
            payload: .iceSelected(ICESelectedPayload(sessionID: UUID(), echo: true))
        )), from: transport)
        await manager.networkChanged()
        await manager.networkChanged()
        await manager.teardown()

        var paths: [ConnectionPathKind] = []
        for await event in events {
            if case .pathChanged(_, let path, _) = event { paths.append(path) }
            if paths.count == 2 { break }
        }
        #expect(paths == [.directLAN, .relay])
    }

    private static func makePromotedManager() async throws -> (PeerConnectionManager, DeviceIdentity, DeviceIdentity, Curve25519.KeyAgreement.PublicKey) {
        let local = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let remote = DeviceIdentity(privateKey: Curve25519.KeyAgreement.PrivateKey())
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(hexString: remote.publicKeyHex)!)
        let relay = RelayClient(identity: local, relayURL: URL(string: "ws://localhost:1")!)
        let manager = PeerConnectionManager(peerHex: remote.publicKeyHex, peerKey: key, identity: local, relay: relay, host: RecoveryHost())
        let transport = DirectTransport(outboundTo: .hostPort(host: "127.0.0.1", port: 1), identity: local, expectedPeer: key)
        await manager.registerProbe(transport, pathKind: .directLAN)
        await manager.handleDirectEvent(.inbound(TransportInbound(
            from: key, fromHex: remote.publicKeyHex,
            payload: .iceSelected(ICESelectedPayload(sessionID: UUID(), echo: true))
        )), from: transport)
        return (manager, local, remote, key)
    }

    @Test("Relay traffic right after promotion keeps the direct link")
    func relayTrafficWithinGraceKeepsLink() async throws {
        let (manager, _, _, _) = try await Self.makePromotedManager()
        #expect(await manager.currentPath == .directLAN)
        await manager.peerUsedRelay(now: Date())
        #expect(await manager.currentPath == .directLAN)
        await manager.teardown()
    }

    @Test("Peer using the relay drops a stale direct link (resume from background)")
    func relayTrafficDropsStaleLink() async throws {
        let (manager, _, _, _) = try await Self.makePromotedManager()
        let later = Date().addingTimeInterval(PeerConnectionManager.staleLinkGracePeriod + 1)
        await manager.peerUsedRelay(now: later)
        #expect(await manager.currentPath == .relay)
        await manager.teardown()
    }

    @Test("Fresh candidate offer drops a stale direct link")
    func candidateOfferDropsStaleLink() async throws {
        let (manager, _, _, _) = try await Self.makePromotedManager()
        let later = Date().addingTimeInterval(PeerConnectionManager.staleLinkGracePeriod + 1)
        await manager.handleRelayICE(.iceCandidates(ICECandidatesPayload(sessionID: UUID(), candidates: [])), now: later)
        #expect(await manager.currentPath == .relay)
        await manager.teardown()
    }

    @Test("New inbound link from the peer replaces a stale one, but not a fresh one")
    func inboundLinkReplacesOnlyStaleLink() async throws {
        let (manager, local, _, _) = try await Self.makePromotedManager()
        let inbound = DirectTransport(
            adopting: NWConnection(host: "127.0.0.1", port: 1, using: .tcp),
            identity: local
        )
        #expect(await manager.beginAdoptIfIdle(inbound, now: Date()) == false)
        #expect(await manager.currentPath == .directLAN)
        let later = Date().addingTimeInterval(PeerConnectionManager.staleLinkGracePeriod + 1)
        #expect(await manager.beginAdoptIfIdle(inbound, now: later) == true)
        #expect(await manager.currentPath == .relay)
        await manager.teardown()
    }
}
