import AVFoundation
import Foundation
import Synchronization
import RxAgentVoice
import RxAgentCore
import Testing
@testable import RxCode
import RxCodeCore

extension PetVoiceUpdateTests {
    @MainActor
    func bindRealtimeNotifications(pet: PetController, connection: PetUpdateTestConnection) async {
        let channel = PetRealtimeVoiceNotifications()
        channel.bind { text in try await connection.send(text: text) }
        channel.connected()
        pet.realtimeNotifications = channel
        await connection.bindNotifications(channel)
    }

    @MainActor
    func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        // Sprite decoding and other parallel tests can occupy the main actor for
        // several seconds before the voice task gets its first turn.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await condition(), "Timed out waiting for the voice state transition")
    }
}

nonisolated final class UnexpectedPetSpeechOutput: PetSpeechOutput {
    private let calls = Mutex(0)
    var prepareCount: Int { calls.withLock { $0 } }
    func prepare(deviceUID: String?, envelope: PetSpeechEnvelope?) async throws {
        calls.withLock { $0 += 1 }
        throw VoiceError.unavailable("Unexpected audio hardware preparation")
    }
    func schedule(_ data: Data, completion: @escaping @Sendable () -> Void) { completion() }
    func stop() {}
    func teardown() {}
}

struct PetUpdateTestEngine: VoiceEngine {
    let connection: PetUpdateTestConnection
    var connectGate: AsyncStream<Void>? = nil
    var displayName: String { "Test" }
    var capabilities: VoiceEngineCapabilities { .init() }
    func readiness() async -> VoiceEngineReadiness { .ready }
    func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection {
        await connection.recordConnect()
        if let connectGate { for await _ in connectGate { break } }
        return connection
    }
}

actor PetUpdateTestConnection: VoiceConnection {
    nonisolated let inputFormat = VoicePCMFormat()
    nonisolated let events: AsyncStream<VoiceEngineEvent>
    private let output: AsyncStream<VoiceEngineEvent>.Continuation
    private(set) var messages: [String] = []
    private var replyID = ""
    private var notifications: PetRealtimeVoiceNotifications?
    private var closeGate: AsyncStream<Void>?
    func holdClose(_ gate: AsyncStream<Void>) { closeGate = gate }
    func bindNotifications(_ value: PetRealtimeVoiceNotifications) { notifications = value }
    private(set) var audioFrames = 0
    private(set) var connectCount = 0
    private(set) var closeCount = 0
    private(set) var interruptCount = 0
    func recordConnect() { connectCount += 1 }

    init() { (events, output) = AsyncStream.makeStream() }
    func send(audio: VoiceAudioFrame) async throws { audioFrames += 1 }
    func send(text: String) async throws {
        messages.append(text)
        replyID = UUID().uuidString
        // Deliberately leave the reply unfinished until the test permits the next update.
        output.yield(.assistantText(itemID: replyID, delta: "Here is the update."))
    }
    func finishReply() async {
        output.yield(.assistantDone(itemID: replyID))
        await notifications?.responseFinished()
    }
    func emit(_ event: VoiceEngineEvent) { output.yield(event) }
    func interrupt(_ interruption: VoiceInterruption) async throws { interruptCount += 1 }
    func submitToolResult(callID: String, result: AgentToolResult) async throws {}
    func close() async {
        closeCount += 1
        if let closeGate { for await _ in closeGate { break } }
        output.finish()
    }
}

@MainActor
final class PetUpdateTestAudio: PetVoiceAudioDriver {
    private(set) var startCount = 0
    private(set) var playCount = 0
    private(set) var queuedFrames = 0
    private(set) var stopCount = 0
    private(set) var flushCount = 0
    func emit(_ frame: VoiceAudioFrame) { output?.yield(frame) }
    private var output: AsyncStream<VoiceAudioFrame>.Continuation?
    override func start(format: VoicePCMFormat) async throws -> AsyncStream<VoiceAudioFrame> {
        startCount += 1
        let (stream, continuation) = AsyncStream<VoiceAudioFrame>.makeStream()
        output = continuation
        return stream
    }
    override func schedulePlayback(_ frame: VoiceAudioFrame) throws {
        playCount += 1
        queuedFrames += 1
        speechPlayback?.begin()
    }
    override func flush() {
        super.flush()
        flushCount += 1
        queuedFrames = 0
    }
    override func stop() { stopCount += 1; output?.finish() }
}
