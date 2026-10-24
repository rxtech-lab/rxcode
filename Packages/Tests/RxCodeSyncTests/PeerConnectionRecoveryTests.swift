import CryptoKit
import Foundation
import Network
import Testing
@testable import RxCodeSync

private actor RecoveryHost: PeerManagerHost {
    func dial(_ endpoint: NWEndpoint, priority: Int, pathKind: ConnectionPathKind, for manager: PeerConnectionManager) async {}
    func localDirectCandidates() async -> [ICECandidate] { [] }
}

@Suite("Peer connection recovery")
struct PeerConnectionRecoveryTests {
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
}
