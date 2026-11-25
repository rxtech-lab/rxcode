import CryptoKit
import Foundation
import Network
import Testing
@testable import RxCodeSync

struct AgentDirectConnectionTests {
    @Test("Phone message and screen frame cross a direct encrypted connection", .timeLimit(.minutes(1)))
    func exchangeAgentPayloads() async throws {
        let phone = DeviceIdentity(privateKey: .init())
        let desktop = DeviceIdentity(privateKey: .init())
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params)
        let ports = AsyncThrowingStream<NWEndpoint.Port, Error>.makeStream()
        let connections = AsyncStream<NWConnection>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port { ports.continuation.yield(port) }
                ports.continuation.finish()
            case .failed(let error): ports.continuation.finish(throwing: error)
            default: break
            }
        }
        listener.newConnectionHandler = { connections.continuation.yield($0) }
        listener.start(queue: DispatchQueue(label: "agent-test.listener"))
        defer {
            listener.cancel()
            ports.continuation.finish()
            connections.continuation.finish()
        }
        var portIterator = ports.stream.makeAsyncIterator()
        let port = try #require(try await portIterator.next())
        let outbound = DirectTransport(outboundTo: .hostPort(host: "127.0.0.1", port: port), identity: phone, expectedPeer: desktop.publicKey)
        let phoneEvents = await outbound.events()
        await outbound.connect()
        var connectionIterator = connections.stream.makeAsyncIterator()
        let connection = try #require(await connectionIterator.next())
        let inbound = DirectTransport(adopting: connection, identity: desktop)
        let desktopEvents = await inbound.events()
        await inbound.connect()

        let agentID = UUID()
        let session = UUID()
        let bytes = Data(repeating: 0x21, count: 65_536)
        let phoneTask = Task {
            for await event in phoneEvents {
                switch event {
                case .stateChanged(.connected):
                    try await outbound.send(.agentRequest(.init(operation: .sendMessage, agentID: agentID, text: "Hello")), to: desktop.publicKey)
                case .inbound(let message):
                    #expect(message.fromHex == desktop.publicKeyHex)
                    guard case .screenFrame(let frame) = message.payload else { throw URLError(.badServerResponse) }
                    #expect(frame.jpeg == bytes)
                    #expect(frame.sessionID == session)
                    return
                default: break
                }
            }
            throw URLError(.networkConnectionLost)
        }
        defer { phoneTask.cancel() }
        for await event in desktopEvents {
            guard case .inbound(let message) = event else { continue }
            #expect(message.fromHex == phone.publicKeyHex)
            guard case .agentRequest(let request) = message.payload else { throw URLError(.badServerResponse) }
            #expect(request.agentID == agentID)
            #expect(request.text == "Hello")
            try await inbound.send(.screenFrame(.init(sessionID: session, seq: 1, displayID: 1, jpeg: bytes, width: 320, height: 240)), to: phone.publicKey)
            break
        }
        try await phoneTask.value
        await inbound.disconnect()
        await outbound.disconnect()
    }
}
