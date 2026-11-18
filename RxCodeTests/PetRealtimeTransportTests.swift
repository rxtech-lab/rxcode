import Foundation
import RxAgentClients
import RxAgentCore
import RxAgentVoice
import Testing
@testable import RxCode

struct PetRealtimeTransportTests {
    @Test("Both realtime transports request speech on the same thread without replaying historical context", .timeLimit(.minutes(1)))
    @MainActor
    func speechProtocolAndContinuity() async throws {
        for transport in [CodexRealtimeTransportPreference.websocket, .webRTC] {
            let directory = FileManager.default.temporaryDirectory.appending(path: "PetRealtimeRPC-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appending(path: "fake-codex")
            let log = directory.appending(path: "requests.jsonl")
            try Self.fakeAppServer.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var archive = PetVoiceHistoryStore.Archive(scope: "test")
            archive.turns = [.init(id: UUID(), sessionID: UUID(), isUser: true, text: "Keep task API-42 pending.", receivedAt: .now)]
            archive.summary = PetVoiceHistoryStore.summarize(archive.turns)
            let channel = PetRealtimeVoiceNotifications()
            let engine = PetCodexRealtimeEngine(
                prepareLaunch: { .init(workingDirectory: directory, transportPreference: transport,
                    voice: "juniper", model: nil, configOverrides: [], sessionKey: "pet-rpc-test", idePort: nil,
                    requestApproval: { _ in true }, onUserTurn: {}) },
                releaseIDEMCP: { _ in }, onLevels: { _, _ in }, onConnected: {}, onToolEvent: { _ in },
                bindWebRTCMuteHandler: { _ in }, notifications: channel,
                makeClient: { _ in CodexClient(binaryPath: executable.path, environment: ["RXCODE_TEST_RPC_LOG": log.path]) },
                makePeer: { FakeCodexVoicePeer(connected: $0) }
            )
            let connection = try await engine.connect(.init(instructions: "Current session instructions.\n" + archive.context))
            try await waitFor { channel.canSend }
            let before = try Self.requests(at: log)
            #expect(before.filter { $0["method"]?.stringValue == "thread/start" }.count == 1)
            #expect(before.first { $0["method"]?.stringValue == "thread/start" }?["params"]?["developerInstructions"]?.stringValue?.contains(archive.id.uuidString) == true)
            #expect(!before.contains { $0["method"]?.stringValue == "thread/realtime/appendSpeech" })
            try await channel.send("RxCode finished API-42. Tests were not run.")
            try await waitFor { channel.completedReplies == 1 }
            try await Task.sleep(for: .milliseconds(50))
            #expect(channel.canSend)
            try await channel.send("The next background task is still running.")
            try await waitFor { channel.completedReplies == 2 }
            try await Task.sleep(for: .milliseconds(50))
            #expect(channel.canSend)
            let after = try Self.requests(at: log)
            let speech = after.filter { $0["method"]?.stringValue == "thread/realtime/appendSpeech" }
            #expect(speech.count == 2)
            #expect(speech.allSatisfy { $0["params"]?["threadId"]?.stringValue == "same-live-thread" })
            #expect(!after.contains { $0["method"]?.stringValue == "thread/realtime/appendText" })
            #expect(after.filter { $0["method"]?.stringValue == "thread/realtime/start" }.count == 1)
            await connection.close()
            #expect(!channel.isReady)
        }
    }

    private static func requests(at url: URL) throws -> [RxAgentCore.JSONValue] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(RxAgentCore.JSONValue.self, from: Data($0.utf8))
        }
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }

    private static let fakeAppServer = #"""
    #!/usr/bin/python3
    import json, os, sys
    def emit(value):
        print(json.dumps(value), flush=True)
    def event(method, params):
        emit({"jsonrpc":"2.0", "method":method, "params":params})
    for line in sys.stdin:
        request = json.loads(line)
        with open(os.environ["RXCODE_TEST_RPC_LOG"], "a") as output:
            output.write(json.dumps(request) + "\n")
        if "id" not in request:
            continue
        method = request.get("method", "")
        result = {"thread":{"id":"same-live-thread"}} if method == "thread/start" else {}
        emit({"jsonrpc":"2.0", "id":request["id"], "result":result})
        if method == "thread/realtime/start":
            event("thread/realtime/started", {"threadId":"same-live-thread"})
        if method == "thread/realtime/appendSpeech":
            event("thread/realtime/transcript/delta", {"role":"assistant", "delta":"Here is the report."})
            event("thread/realtime/outputAudio/delta", {"audio":{"data":"AQABAA==", "sampleRate":24000, "numChannels":1}})
            event("thread/realtime/transcript/done", {"role":"assistant", "text":"Here is the report."})
            event("thread/realtime/outputAudio/delta", {"audio":{"data":"AQABAA==", "sampleRate":24000, "numChannels":1}})
            event("thread/realtime/transcript/done", {"role":"assistant", "text":"Here is the report."})
    """#
}

private nonisolated final class FakeCodexVoicePeer: PetCodexVoicePeer, Sendable {
    private let connected: @Sendable (CodexRealtimePeer.State) -> Void
    init(connected: @escaping @Sendable (CodexRealtimePeer.State) -> Void) { self.connected = connected }
    func makeOffer() async throws -> String { connected(.connected); return "fake-offer-no-hardware" }
    func accept(answer: String) async throws {}
    func setMicrophoneMuted(_ muted: Bool) {}
    func levels() async -> (input: Double, output: Double) { (0, 0) }
    func close() {}
}
