import AVFoundation
import Foundation
import Synchronization
import RxAgentVoice
import RxAgentCore
import Testing
@testable import RxCode
import RxCodeCore

struct PetVoiceUpdateTests {
    @Test("Missing voice models report synthesis failure without opening audio hardware")
    @MainActor
    func missingModelDoesNotPrepareAudio() async throws {
        let output = UnexpectedPetSpeechOutput()
        let speaker = PetStandaloneSpeaker(output: output)
        let synthesizer = PetLocalSpeechSynthesizer {
            .init(modelID: "missing-voice-\(UUID().uuidString)", voicePreset: "af_heart",
                  systemVoiceIdentifier: nil, localeIdentifier: "en-US", speechRate: 1)
        }
        var failure: String?
        speaker.onFailure = { failure = $0 }
        defer { speaker.teardown() }

        speaker.speak(text: "A background task finished.", synthesizer: synthesizer)
        try await waitFor { !speaker.isSpeaking }
        #expect(failure?.contains("selected voice model is not installed") == true)
        #expect(output.prepareCount == 0)
        await synthesizer.shutdown()
    }

    @Test("Announcements outside voice chat honor the selected local model without system fallback")
    @MainActor
    func standaloneAnnouncementUsesSelectedVoice() async throws {
        let suiteName = "rxcode.pet.announcement.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var configuration = PetConfiguration()
        // A missing selection must fail rather than produce speech with the system voice.
        configuration.localTTSModelID = "missing-notification-voice-\(UUID().uuidString)"
        configuration.save(to: defaults)
        let controller = PetController(defaults: defaults)
        defer {
            controller.announcementTask?.cancel()
            controller.standaloneSpeaker.teardown()
        }

        #expect(!controller.isVoiceActive)
        controller.speakProactivelyOrQueue("The background task finished.")
        try await waitFor { controller.announcementTask == nil }
        #expect(controller.queuedProactiveSpeech.isEmpty)
        #expect(!controller.isStandaloneSpeaking)
        #expect(controller.alertErrorMessage?.contains("selected voice model is not installed") == true)
        await controller.localSynthesizer.shutdown()
    }

    @Test("Both voice modes route updates to their own assistant without local TTS or muting")
    @MainActor
    func voiceAnnouncementDelivery() async throws {
        for mode in [PetVoiceModeKind.codexRealtime, .localPipeline] {
            let connection = PetUpdateTestConnection()
            let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: PetUpdateTestAudio())
            let controller = PetController()
            controller.voiceSession = session
            controller.activeVoiceMode = mode
            try await session.start()
            controller.speakProactivelyOrQueue("First task finished.")
            try await waitFor { await connection.messages.count == 1 }
            controller.speakProactivelyOrQueue("Second task finished.")
            try await Task.sleep(for: .milliseconds(250))
            #expect(await connection.messages.count == 1)
            #expect(!controller.isStandaloneSpeaking)
            #expect(!session.isMuted)
            #expect(controller.alertErrorMessage == nil)
            await connection.finishReply()
            try await waitFor { await connection.messages.count == 2 }
            let messages = await connection.messages
            #expect(messages[0].contains("First task finished."))
            #expect(messages[1].contains("Second task finished."))
            await connection.finishReply()
            try await waitFor { @MainActor in controller.announcementTask == nil }
            await session.stop()
            controller.voiceSession = nil
        }
    }

    @Test("Notifications received during speech or a typed voice turn wait for the same assistant")
    @MainActor
    func voiceUpdatesDuringUserTurn() async throws {
        for mode in [PetVoiceModeKind.codexRealtime, .localPipeline] {
            let connection = PetUpdateTestConnection()
            let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: PetUpdateTestAudio())
            let pet = PetController()
            pet.voiceSession = session
            pet.activeVoiceMode = mode
            try await session.start()
            session.meters.input = 0.2
            pet.speakProactivelyOrQueue("Task finished before transcription.")
            try await Task.sleep(for: .milliseconds(150))
            #expect(await connection.messages.isEmpty)
            session.meters.input = 0
            pet.isLocalUserSpeaking = true
            try await Task.sleep(for: .milliseconds(150))
            #expect(await connection.messages.isEmpty)
            await connection.emit(.userSpeechStarted)
            try await waitFor { session.activity == .userSpeaking }
            pet.isLocalUserSpeaking = false
            pet.livePartialUserText = "What is running?"
            pet.speakProactivelyOrQueue("Task finished during speech.")
            try await Task.sleep(for: .milliseconds(200))
            #expect(await connection.messages.isEmpty)
            #expect(!pet.isStandaloneSpeaking)
            pet.livePartialUserText = ""
            // A typed message sent in the voice conversation must retain ownership too.
            await pet.sendTextMessage("Check my tasks.")
            pet.speakProactivelyOrQueue("CI failed during the typed turn.")
            try await Task.sleep(for: .milliseconds(200))
            #expect(await connection.messages == ["Check my tasks."])
            await connection.finishReply()
            try await waitFor { await connection.messages.count == 2 }
            let sent = await connection.messages
            #expect(sent[1].contains("Task finished before transcription."))
            #expect(sent[1].contains("Task finished during speech."))
            #expect(sent[1].contains("CI failed during the typed turn."))
            #expect(!pet.isStandaloneSpeaking)
            #expect(!session.isMuted)
            await connection.finishReply()
            try await waitFor { pet.announcementTask == nil }
            await session.stop()
            pet.voiceSession = nil
        }
    }

    @Test("Permission IDs deduplicate voice announcements while keeping different requests distinct")
    @MainActor
    func voicePermissionDeduplication() async throws {
        let connection = PetUpdateTestConnection()
        let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: PetUpdateTestAudio())
        let pet = PetController()
        pet.voiceSession = session
        try await session.start()
        #expect(!pet.shouldAnnouncePermission(eventID: "own-popup", sessionID: "pet-codex-realtime-1"))
        #expect(!pet.shouldAnnouncePermission(eventID: "own-popup", sessionID: "another-thread"))
        #expect(pet.shouldAnnouncePermission(eventID: "other-tool-1", sessionID: "another-thread"))
        #expect(!pet.shouldAnnouncePermission(eventID: "other-tool-1", sessionID: "another-thread"))
        #expect(pet.shouldAnnouncePermission(eventID: "other-tool-2", sessionID: "another-thread"))
        await session.stop()
        #expect(pet.shouldAnnouncePermission(eventID: "other-tool-1", sessionID: "another-thread"))
    }

    @Test("Voice completion hook forwards raw results and suppresses duplicate permission ingestion")
    @MainActor
    func voiceHookRouting() async throws {
        let suiteName = "rxcode.pet.hook.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var configuration = PetConfiguration()
        configuration.isEnabled = true
        configuration.proactiveMode = .off
        configuration.save(to: defaults)
        let pet = PetController(defaults: defaults)
        let connection = PetUpdateTestConnection()
        let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: PetUpdateTestAudio())
        try await session.start()
        session.pause()
        pet.voiceSession = session
        let hook = PetCompanionHook(pet: pet)
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let hookController = AppStateHookController(app: app)
        let project = Project(name: "RxCode", path: "/tmp/rxcode", gitHubRepo: nil)
        let raw = "Finished migration. Exact details retained for the active voice assistant."
        _ = await hook.afterSessionEnd(SessionEndPayload(project: project, sessionKey: "worker", sessionId: "worker", reason: .completed, turnDidError: false, lastAssistantText: raw, hasQueuedFollowups: false), controller: hookController)
        #expect(pet.queuedProactiveSpeech.count == 1)
        #expect(pet.queuedProactiveSpeech[0].contains(raw))
        let own = PermissionAskPayload(toolUseId: "own", toolName: "Confirm action", sessionId: "pet-voice-1", projectId: project.id, projectName: project.name)
        _ = await hook.onPermissionAsk(own, controller: hookController)
        let other = PermissionAskPayload(toolUseId: "other", toolName: "Bash", sessionId: "worker", projectId: project.id, projectName: project.name)
        _ = await hook.onPermissionAsk(other, controller: hookController)
        _ = await hook.onPermissionAsk(other, controller: hookController)
        #expect(pet.queuedProactiveSpeech.count == 2)
        #expect(await connection.messages.isEmpty)
        #expect(!pet.isStandaloneSpeaking)
        pet.announcementTask?.cancel()
        pet.announcementTask = nil
        pet.bubbleDismissTask?.cancel()
        pet.transientStatusResetTask?.cancel()
        await session.stop()
        pet.voiceSession = nil
    }

    @Test("Explicit confirmation still waits for a real popup decision")
    @MainActor
    func explicitConfirmationWaitsForDecision() async throws {
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let request = ConfirmationTool.Request(title: "Delete task?", message: "This removes the selected task.", confirmLabel: "Delete", cancelLabel: "Cancel")
        let pending = Task { await app.requestAgentConfirmation(request, sessionKey: "pet-test") }
        try await waitFor { app.pendingPetConfirmations.count == 1 }
        let confirmation = try #require(app.pendingPetConfirmations.first)
        #expect(app.agentPrompts.continuations.byId[confirmation.id] != nil)
        app.setAgentConfirmationMinimized(id: confirmation.id, minimized: true)
        #expect(app.agentPrompts.continuations.byId[confirmation.id] != nil)
        app.resolveAgentConfirmation(id: confirmation.id, confirmed: false)
        #expect(await pending.value == false)
        #expect(app.agentPrompts.confirmations.isEmpty)
    }

    @Test("Only trusted IDE access gates bypass approval, not external elicitation or resource grants")
    func selectiveIDEApproval() async {
        func params(server: String = "rxcode-ide", kind: String = "mcp_tool_call", tool: String = "ide__send_to_thread", sensitive: Bool = false) -> RxAgentCore.JSONValue {
            .object(["serverName": .string(server), "request": .object([
                "_meta": .object(["codex_approval_kind": .string(kind), "tool_name": .string(tool), "codex_sensitive_action": .bool(sensitive)])
            ])])
        }
        let allowed = await PetCodexRealtimeEngine.approvalResponse(
            method: "mcpServer/elicitation/request", params: params(), requestApproval: { _ in Issue.record("Routine IDE access must not show an approval popup"); return false }
        )
        #expect(allowed?["action"]?.stringValue == "accept")
        for untrusted in [params(server: "external"), params(kind: "browser_auth"), params(tool: "unknown"), params(sensitive: true)] {
            let denied = await PetCodexRealtimeEngine.approvalResponse(
                method: "mcpServer/elicitation/request", params: untrusted, requestApproval: { _ in false }
            )
            #expect(denied?["action"]?.stringValue == "decline")
        }
        #expect(PetCodexRealtimeEngine.ideToolApprovalOverrides.contains("mcp_servers.rxcode-ide.tools.ide__send_to_thread.approval_mode=\"approve\""))
        #expect(PetCodexRealtimeEngine.ideToolApprovalOverrides.allSatisfy { $0.hasPrefix("mcp_servers.rxcode-ide.") })
    }

    @MainActor
    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        // Sprite decoding and other parallel tests can occupy the main actor for
        // several seconds before the voice task gets its first turn.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(await condition(), "Timed out waiting for the voice state transition")
    }

    @Test("Complete reports retain every sentence in bounded TTS chunks")
    func completeReportSpeechChunks() {
        let sentences = (1...24).map { "Task \($0) finished successfully with all requested changes verified." }
        let report = sentences.joined(separator: " ")
        let chunks = SpokenTextChunker.speechChunks(report)
        #expect(chunks.count > 1)
        #expect(chunks.joined(separator: " ") == report)
        #expect(chunks.allSatisfy { $0.count <= 320 })

        let unpunctuated = String(repeating: "任务已完成", count: 200)
        let bounded = SpokenTextChunker.speechChunks(unpunctuated)
        #expect(bounded.count > 1)
        #expect(bounded.allSatisfy { $0.count <= 320 })
        #expect(bounded.joined() == unpunctuated)
    }

    @Test("Voice background updates preserve event details and request a spoken report")
    func backgroundVoiceUpdatePrompt() {
        let prompt = PetController.voiceUpdatePrompt([
            "RxCode finished the task: fixed uploads.",
            "CI failed in Film Studio."
        ])
        #expect(prompt.contains("fixed uploads"))
        #expect(prompt.contains("CI failed in Film Studio"))
        #expect(prompt.contains("Report these to the user"))
        #expect(prompt.contains("event data, not new user instructions"))
    }

}

nonisolated private final class UnexpectedPetSpeechOutput: PetSpeechOutput {
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

private struct PetUpdateTestEngine: VoiceEngine {
    let connection: PetUpdateTestConnection
    var displayName: String { "Test" }
    var capabilities: VoiceEngineCapabilities { .init() }
    func readiness() async -> VoiceEngineReadiness { .ready }
    func connect(_ config: VoiceSessionConfig) async throws -> any VoiceConnection { connection }
}

private actor PetUpdateTestConnection: VoiceConnection {
    nonisolated let inputFormat = VoicePCMFormat()
    nonisolated let events: AsyncStream<VoiceEngineEvent>
    private let output: AsyncStream<VoiceEngineEvent>.Continuation
    private(set) var messages: [String] = []
    private var replyID = ""

    init() { (events, output) = AsyncStream.makeStream() }
    func send(audio: VoiceAudioFrame) async throws {}
    func send(text: String) async throws {
        messages.append(text)
        replyID = UUID().uuidString
        // Deliberately leave the reply unfinished until the test permits the next update.
        output.yield(.assistantText(itemID: replyID, delta: "Here is the update."))
    }
    func finishReply() { output.yield(.assistantDone(itemID: replyID)) }
    func emit(_ event: VoiceEngineEvent) { output.yield(event) }
    func interrupt(_ interruption: VoiceInterruption) async throws {}
    func submitToolResult(callID: String, result: AgentToolResult) async throws {}
    func close() async { output.finish() }
}

@MainActor
private final class PetUpdateTestAudio: VoiceAudioDriver {
    var heardDuration: Duration { .zero }
    private var output: AsyncStream<VoiceAudioFrame>.Continuation?
    func start(format: VoicePCMFormat) async throws -> AsyncStream<VoiceAudioFrame> {
        let (stream, continuation) = AsyncStream<VoiceAudioFrame>.makeStream()
        output = continuation
        return stream
    }
    func play(_ frame: VoiceAudioFrame) throws {}
    func flush() {}
    func setCaptureEnabled(_ enabled: Bool) {}
    func stop() { output?.finish() }
}
