import AVFoundation
import Foundation
import Synchronization
import RxAgentVoice
import RxAgentCore
import Testing
@testable import RxCode
import RxCodeCore

struct PetVoiceUpdateTests {
    @Test("Hangup closes capture immediately and a fast reopen waits for the prior transcript flush")
    @MainActor
    func hangupAndFastReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PetFastReopen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PetFastReopenDefaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = PetConfiguration()
        config.isMuted = false
        config.save(to: defaults)
        let store = PetVoiceHistoryStore(directory: root)
        let pet = PetController(defaults: defaults, historyStore: store)
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let scope = pet.voiceHistoryScope(in: app)
        let archive = try await store.archive(scope: scope)
        let typedSession = UUID()
        try await store.append(scope: scope, conversationID: archive.id, turns: [
            .init(id: UUID(), sessionID: typedSession, isUser: true, text: "Remember the blue cover.", receivedAt: .now)
        ])
        let initialContext = try await pet.prepareVoiceHistory(in: app).context
        #expect(initialContext.contains("blue cover"))
        let connection = PetUpdateTestConnection()
        let audio = PetUpdateTestAudio()
        let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: audio)
        pet.voiceSession = session
        pet.activeVoiceMode = .localPipeline
        try await session.start()
        await connection.emit(.userTranscript(itemID: "final", text: "Keep API-42 pending until verification.", isFinal: true))
        try await waitFor { !session.transcript.isEmpty }
        let (closeGate, releaseClose) = AsyncStream<Void>.makeStream()
        await connection.holdClose(closeGate)
        let stopping = Task { await pet.stopVoice(drainAnnouncements: false) }
        try await waitFor { await connection.closeCount == 1 }
        #expect(!audio.captureEnabled)
        #expect(!pet.isMuted)
        var didPrepare = false
        let reopening = Task {
            let context = try await pet.prepareVoiceHistory(in: app).context
            didPrepare = true
            return context
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!didPrepare)
        releaseClose.yield(())
        releaseClose.finish()
        await stopping.value
        let context = try await reopening.value
        #expect(context.contains("API-42"))
        let reopened = try await PetVoiceHistoryStore(directory: root).archive(scope: scope)
        #expect(reopened.turns.map(\.text) == ["Remember the blue cover.", "Keep API-42 pending until verification."])
        #expect(Set(reopened.turns.map(\.sessionID)).count == 2)
        #expect(pet.voiceHistoryBinding?.conversationID == archive.id)
        #expect(pet.voiceSession == nil)
        let binding = pet.voiceHistoryBinding
        do {
            _ = try await pet.prepareVoiceHistory(in: app, generation: UUID())
            Issue.record("An obsolete start must not replace a newer conversation binding")
        } catch is CancellationError {}
        #expect(pet.voiceHistoryBinding === binding)
    }

    @Test("Cancelling one submitted report cannot retire a newer report with identical text")
    @MainActor
    func reportQueueUsesStableIDs() async throws {
        let suite = "PetReportIDs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = PetConfiguration()
        config.isEnabled = true
        config.proactiveMode = .voiceAndBubble
        config.save(to: defaults)
        let pet = PetController(defaults: defaults)
        let connection = PetUpdateTestConnection()
        let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: PetUpdateTestAudio())
        pet.voiceSession = session
        pet.activeVoiceMode = .codexRealtime
        await bindRealtimeNotifications(pet: pet, connection: connection)
        try await session.start()
        let first = UUID(), second = UUID()
        var firstDelivered = 0, secondDelivered = 0
        pet.deliverScheduledReport(id: first, title: "First", text: "Two tasks remain pending.") { firstDelivered += 1 }
        try await waitFor { await connection.messages.count == 1 }
        pet.deliverScheduledReport(id: second, title: "Second", text: "Two tasks remain pending.") { secondDelivered += 1 }
        pet.cancelScheduledReport(id: first)
        await connection.finishReply()
        try await waitFor { await connection.messages.count == 2 }
        #expect(firstDelivered == 0 && secondDelivered == 0)
        await connection.finishReply()
        try await waitFor { secondDelivered == 1 }
        #expect(firstDelivered == 0)
        #expect(pet.queuedProactiveSpeech.isEmpty)
        await pet.stopVoice(drainAnnouncements: false)
        pet.bubbleDismissTask?.cancel()
    }

    @Test("Received completed turns survive a disconnect and manual hangup without replaying partial text")
    @MainActor
    func completedHistoryOnDisconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PetDisconnectHistory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PetVoiceHistoryStore(directory: root)
        let archive = try await store.archive(scope: "workspace-project")
        let pet = PetController(historyStore: store)
        pet.voiceHistoryBinding = PetVoiceHistoryBinding(scope: archive.scope, conversationID: archive.id)
        let connection = PetUpdateTestConnection()
        let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: PetUpdateTestAudio())
        pet.voiceSession = session
        pet.activeVoiceMode = .codexRealtime
        try await session.start()
        pet.startVoiceStateSyncLoop(for: session)
        await connection.emit(.userTranscript(itemID: "user", text: "Keep API-42 pending.", isFinal: true))
        try await session.send(text: "Request")
        await connection.finishReply()
        await connection.emit(.assistantText(itemID: "partial", delta: "unfinished draft"))
        await connection.emit(.closed(reason: "test drop"))
        try await waitFor { session.lifecycle == .stopped }
        try await waitFor { (try? await store.archive(scope: archive.scope).turns.count) == 2 }
        await pet.stopVoice(drainAnnouncements: false)
        let reopened = try await PetVoiceHistoryStore(directory: root).archive(scope: archive.scope)
        #expect(reopened.turns.count == 2)
        #expect(!reopened.turns.contains { $0.text.contains("unfinished draft") })
        #expect(reopened.context.contains("API-42"))
        pet.bubbleDismissTask?.cancel()
    }

    @Test("Scheduled reports wait for an active realtime reply and remain audible with a muted microphone")
    @MainActor
    func scheduledReportDuringRealtimeReply() async throws {
        for transport in [CodexRealtimeTransportPreference.webRTC, .websocket] {
            let suite = "PetScheduledVoice-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var config = PetConfiguration()
            config.isEnabled = true
            config.proactiveMode = .voiceAndBubble
            config.codexTransport = transport
            config.isMuted = true
            config.save(to: defaults)
            let pet = PetController(defaults: defaults)
            let connection = PetUpdateTestConnection()
            let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: PetUpdateTestAudio())
            pet.voiceSession = session
            pet.activeVoiceMode = .codexRealtime
            await bindRealtimeNotifications(pet: pet, connection: connection)
            session.setMuted(true)
            try await session.start()
            let channel = try #require(pet.realtimeNotifications)
            channel.responseStarted()
            var delivered = 0
            let id = UUID()
            pet.deliverScheduledReport(id: id, title: "Progress", text: "The project has two pending tasks.") { delivered += 1 }
            pet.deliverScheduledReport(id: id, title: "Progress", text: "The project has two pending tasks.") { delivered += 1 }
            try await Task.sleep(for: .milliseconds(150))
            #expect(await connection.messages.isEmpty)
            channel.responseFinished()
            try await waitFor { await connection.messages.count == 1 }
            #expect(delivered == 0)
            #expect(session.isMuted && pet.voiceSession === session)
            #expect(!pet.isStandaloneSpeaking)
            await connection.finishReply()
            // Acknowledgement happens at completion, so immediate hangup cannot requeue it.
            try await waitFor { delivered == 1 }
            await pet.stopVoice(drainAnnouncements: false)
            #expect(pet.queuedProactiveSpeech.isEmpty)
            #expect(await connection.messages.count == 1)
            pet.bubbleDismissTask?.cancel()
        }
    }

    @Test("A due projectless reminder uses the ongoing realtime call and waits behind its reply")
    @MainActor
    func dueReminderDuringRealtimeCall() async throws {
        for transport in [CodexRealtimeTransportPreference.webRTC, .websocket] {
            let suite = "PetDueReminder-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var config = PetConfiguration()
            config.isEnabled = true; config.proactiveMode = .voiceAndBubble
            config.codexTransport = transport; config.isMuted = true
            config.save(to: defaults)
            let pet = PetController(defaults: defaults)
            let connection = PetUpdateTestConnection()
            let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: PetUpdateTestAudio())
            pet.voiceSession = session
            pet.activeVoiceMode = .codexRealtime
            await bindRealtimeNotifications(pet: pet, connection: connection)
            session.setMuted(true)
            try await session.start()
            let channel = try #require(pet.realtimeNotifications)
            channel.responseStarted()
            let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
            app.scheduledPetReportReceiver = pet
            var reminder = ScheduledTask(name: "Stretch", prompt: "Take a stretch break.", cronExpression: "")
            reminder.petScheduleKind = .reminder
            reminder.dueAt = .now.addingTimeInterval(-1)
            app.scheduledTasks = [reminder]
            app.runDueScheduledTasks(since: .now, now: .now)
            try await waitFor { app.scheduledTasks[0].pendingPetReport != nil }
            try await Task.sleep(for: .milliseconds(150))
            #expect(await connection.messages.isEmpty)
            channel.responseFinished()
            try await waitFor { await connection.messages.count == 1 }
            let sent = await connection.messages
            #expect(sent[0].contains(reminder.prompt))
            #expect(pet.petState.bubble?.text == reminder.prompt)
            #expect(pet.voiceSession === session && session.isMuted && !pet.isStandaloneSpeaking)
            #expect(app.taskBoards.isEmpty && app.sessionStates.isEmpty)
            await connection.finishReply()
            try await waitFor { app.scheduledTasks[0].petReportDeliveredAt != nil }
            app.runDueScheduledTasks(since: .now, now: .now.addingTimeInterval(60))
            #expect(await connection.messages.count == 1)
            await pet.stopVoice(drainAnnouncements: false)
            pet.bubbleDismissTask?.cancel()
        }
    }

    @Test("Microphone mute keeps the same voice connection, transcript and assistant playback")
    @MainActor
    func microphoneMutePreservesConversation() async throws {
        for mode in [PetVoiceModeKind.codexRealtime, .localPipeline] {
            let suite = "PetMicrophoneMuteTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            var config = PetConfiguration()
            config.isMuted = false
            config.save(to: defaults)
            let pet = PetController(defaults: defaults)
            let connection = PetUpdateTestConnection()
            let audio = PetUpdateTestAudio()
            let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection), audio: audio)
            pet.voiceSession = session
            pet.activeVoiceMode = mode
            if mode == .codexRealtime { await bindRealtimeNotifications(pet: pet, connection: connection) }
            try await session.start()
            let frame = try VoiceAudioFrame(data: Data([1, 0]), format: .init())
            audio.emit(frame)
            try await waitFor { await connection.audioFrames == 1 }
            try await session.send(text: "Remember this conversation.")
            try await waitFor { !session.transcript.isEmpty }
            let transcriptIDs = session.transcript.map(\.id)
            let startGeneration = pet.voiceStartGeneration

            pet.toggleMute()
            #expect(pet.isMuted && session.isMuted)
            #expect(!audio.captureEnabled)
            #expect(pet.voiceStartGeneration == startGeneration)
            audio.emit(frame) // Simulate a frame already queued at the instant of mute.
            await connection.emit(.assistantAudio(itemID: "reply", frame))
            try await waitFor { audio.playCount == 1 }
            try await Task.sleep(for: .milliseconds(100))
            #expect(await connection.audioFrames == 1)
            #expect(pet.voiceSession === session)
            #expect(pet.activeVoiceMode == mode)
            #expect(session.lifecycle == .active)
            #expect(session.transcript.prefix(transcriptIDs.count).map(\.id) == transcriptIDs)
            #expect(await connection.closeCount == 0)
            #expect(await connection.interruptCount == 0)
            #expect(audio.flushCount == 0 && audio.stopCount == 0)

            pet.toggleMute()
            #expect(!session.isMuted && audio.captureEnabled)
            audio.emit(frame)
            try await waitFor { await connection.audioFrames == 2 }
            await connection.emit(.assistantAudio(itemID: "reply", frame))
            try await waitFor { audio.playCount == 2 }
            #expect(audio.startCount == 1)
            #expect(await connection.connectCount == 1)
            #expect(pet.voiceSession === session)
            await session.stop()
            pet.voiceSession = nil
        }
    }

    @Test("Muting during voice connection does not cancel startup or reopen the microphone")
    @MainActor
    func muteWhileConnecting() async throws {
        let connection = PetUpdateTestConnection()
        let audio = PetUpdateTestAudio()
        let (gate, release) = AsyncStream<Void>.makeStream()
        let session = VoiceSession(engine: PetUpdateTestEngine(connection: connection, connectGate: gate), audio: audio)
        let suite = "PetConnectingMuteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pet = PetController(defaults: defaults)
        pet.configuration.isMuted = false
        pet.voiceSession = session
        let starting = Task { try await session.start() }
        try await waitFor { session.lifecycle == .connecting }
        pet.toggleMute()
        release.yield(())
        release.finish()
        try await starting.value
        #expect(session.lifecycle == .active && session.isMuted)
        #expect(!audio.captureEnabled)
        #expect(pet.voiceSession === session)
        pet.toggleMute()
        #expect(audio.captureEnabled)
        #expect(await connection.connectCount == 1)
        #expect(await connection.closeCount == 0)
        await session.stop()
        pet.voiceSession = nil
    }

    @Test("Capture gates preserve assistant speech and replay mute to late WebRTC bindings")
    @MainActor
    func captureGatesDoNotMutePlayback() {
        let signal = PetSpeechPlaybackSignal()
        let hardware = PetVoiceAudioDriver()
        hardware.speechPlayback = signal
        signal.updateRemoteLevel(0.7)
        hardware.setCaptureEnabled(false)
        #expect(signal.isActive)
        var mutedStates: [Bool] = []
        hardware.captureDidChange = { mutedStates.append(!$0) }
        #expect(mutedStates == [true])
        hardware.setCaptureEnabled(true)
        hardware.setCaptureEnabled(false)
        #expect(mutedStates == [true, false, true])
        #expect(signal.isActive)
        #expect(signal.envelope.level() == 0.7)
    }

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
        #expect(controller.queuedProactiveSpeech == ["The background task finished."])
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
            if mode == .codexRealtime { await bindRealtimeNotifications(pet: controller, connection: connection) }
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
            if mode == .codexRealtime { await bindRealtimeNotifications(pet: pet, connection: connection) }
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
        configuration.proactiveMode = .voiceAndBubble
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
        let completion = SessionEndPayload(project: project, sessionKey: "worker", sessionId: "worker", reason: .completed,
            turnDidError: false, lastAssistantText: raw, hasQueuedFollowups: false, deliveryID: "same-completed-turn")
        _ = await hook.afterSessionEnd(completion, controller: hookController)
        _ = await hook.afterSessionEnd(completion, controller: hookController)
        _ = await hook.afterSessionEnd(SessionEndPayload(project: project, sessionKey: "worker", sessionId: "worker",
            reason: .completed, turnDidError: false, lastAssistantText: "An intermediate turn", hasQueuedFollowups: true,
            deliveryID: "queued-follow-up"), controller: hookController)
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
    private func bindRealtimeNotifications(pet: PetController, connection: PetUpdateTestConnection) async {
        let channel = PetRealtimeVoiceNotifications()
        channel.bind { text in try await connection.send(text: text) }
        channel.connected()
        pet.realtimeNotifications = channel
        await connection.bindNotifications(channel)
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

private actor PetUpdateTestConnection: VoiceConnection {
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
private final class PetUpdateTestAudio: VoiceAudioDriver {
    var heardDuration: Duration { .zero }
    private(set) var captureEnabled = false
    private(set) var startCount = 0
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var flushCount = 0
    func emit(_ frame: VoiceAudioFrame) { output?.yield(frame) }
    private var output: AsyncStream<VoiceAudioFrame>.Continuation?
    func start(format: VoicePCMFormat) async throws -> AsyncStream<VoiceAudioFrame> {
        startCount += 1
        let (stream, continuation) = AsyncStream<VoiceAudioFrame>.makeStream()
        output = continuation
        return stream
    }
    func play(_ frame: VoiceAudioFrame) throws { playCount += 1 }
    func flush() { flushCount += 1 }
    func setCaptureEnabled(_ enabled: Bool) { captureEnabled = enabled }
    func stop() { stopCount += 1; output?.finish() }
}
