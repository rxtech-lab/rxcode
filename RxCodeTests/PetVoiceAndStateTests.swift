import AVFoundation
import Foundation
import RxAgentVoice
import RxAgentCore
import Testing
@testable import RxCode
import RxCodeCore

struct PetVoiceAndStateTests {

    @Test("Pet mute decodes legacy preferences and persists across launches")
    func persistentPetMute() throws {
        var config = PetConfiguration()
        let encoded = try JSONEncoder().encode(config)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "isMuted")
        let decoded = try JSONDecoder().decode(PetConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.isMuted == nil)
        config.isMuted = true
        let restored = try JSONDecoder().decode(PetConfiguration.self, from: JSONEncoder().encode(config))
        #expect(restored.isMuted == true)
    }

    @Test("Muting an idle pet keeps the next notification visible and silent")
    @MainActor
    func idleMuteSilencesNotificationSpeech() throws {
        let suite = "PetMuteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = PetConfiguration()
        config.isEnabled = true
        config.proactiveMode = .voiceAndBubble
        config.isMuted = false
        config.save(to: defaults)
        let controller = PetController(defaults: defaults)
        controller.toggleMute()
        controller.notifyProactiveEvent(title: nil, spokenText: "A task has finished",
                                       mood: .happy, status: .celebrating, action: nil)
        #expect(controller.isMuted)
        #expect(controller.petState.bubble?.text == "A task has finished")
        #expect(controller.queuedProactiveSpeech.isEmpty)
        #expect(controller.announcementTask == nil)
        #expect(!controller.isStandaloneSpeaking)
        let reopened = PetController(defaults: defaults)
        #expect(reopened.isMuted)
        #expect(reopened.speakProactivelyOrQueue("While still muted") == nil)
        controller.toggleMute()
        #expect(controller.queuedProactiveSpeech.isEmpty)
        #expect(controller.speakProactivelyOrQueue("A new announcement") != nil)
        controller.announcementTask?.cancel()
        controller.bubbleDismissTask?.cancel()
        controller.transientStatusResetTask?.cancel()
    }

    @Test("Mute stops standalone speech and voice previews already being prepared")
    @MainActor
    func muteStopsPendingPlayback() throws {
        let suite = "PetPendingMuteTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pet = PetController(defaults: defaults)
        let preview = PetVoiceDraftPreview()
        preview.play(configuration: pet.configuration, controller: pet)
        pet.standaloneSpeaker.speak(text: "Current report", synthesizer: pet.localSynthesizer)
        #expect(preview.isPlaying && pet.isStandaloneSpeaking)
        pet.toggleMute()
        #expect(!preview.isPlaying && !pet.standaloneSpeaker.isSpeaking && !pet.isStandaloneSpeaking)
        preview.play(configuration: pet.configuration, controller: pet)
        #expect(!preview.isPlaying)
    }

    @Test("Pet settings and voice management target a dedicated window")
    @MainActor
    func settingsUseDedicatedWindow() {
        let controller = PetController()
        var windowIDs: [String] = []
        controller.openWindowAction = { windowIDs.append($0) }
        controller.openSettingsWindow()
        #expect(controller.settingsTab == .generalAgent)
        controller.performQuickAction(.openVoiceSettings)
        #expect(controller.settingsTab == .voice)
        #expect(!controller.isChoosingSpeechVoice)
        controller.openSpeechVoicePicker()
        #expect(controller.settingsTab == .voice && controller.isChoosingSpeechVoice)
        #expect(PetSettingsView.SettingsTab.allCases.map(\.title).filter { $0.hasPrefix("Voice") } == ["Voice"])
        #expect(windowIDs == Array(repeating: PetWindows.settingsID, count: 3))
        #expect(controller.activeSheet == nil)
    }

    @Test("Speech voice choices survive engine switches and older local preferences")
    func independentSpeechVoiceSelection() throws {
        var config = PetConfiguration()
        config.codexVoice = CodexRealtimeVoicePreset.maple.rawValue
        config.selectLocalVoice(modelID: "mlx-community/Kokoro-82M-bf16")
        config.localTTSVoicePreset = "af_bella"
        let legacy = try JSONEncoder().encode(config)
        let selection = FlowcySpeechSelection(
            model: .init(modelId: "fixture-audio", alias: "Speech", provider: "gateway", labels: ["audio"]),
            voice: .init(id: "speaker", name: "Speaker")
        )
        config.flowcyVoice = selection
        for mode in PetVoiceModeKind.allCases {
            config.voiceMode = mode
            let restored = try JSONDecoder().decode(PetConfiguration.self, from: JSONEncoder().encode(config))
            #expect(restored.speechSynthesisConfiguration().flowcyVoice == selection)
            #expect(restored.resolvedCodexVoice == .maple)
        }
        config.selectLocalVoice(modelID: config.localTTSModelID)
        let local = config.speechSynthesisConfiguration()
        #expect(local.flowcyVoice == nil)
        #expect(local.voicePreset == "af_bella")
        let migrated = try JSONDecoder().decode(PetConfiguration.self, from: legacy)
        #expect(migrated.flowcyVoice == nil)
        #expect(migrated.localTTSModelID == config.localTTSModelID)
        #expect(migrated.localTTSVoicePreset == "af_bella")
        #expect(migrated.resolvedCodexVoice == .maple)
    }

    @Test("Voice preview survives replacement and finishes playback",
          .enabled(if: ProcessInfo.processInfo.environment["RXCODE_TEST_VOICE_PREVIEW"] == "1"),
          .timeLimit(.minutes(1)))
    @MainActor
    func voicePreviewPlayback() async throws {
        let synthesizer = PetLocalSpeechSynthesizer {
            .init(modelID: ProcessInfo.processInfo.environment["RXCODE_TEST_VOICE_MODEL"] ?? PetConfiguration.systemTTSModelID,
                  voicePreset: "af_heart",
                  systemVoiceIdentifier: nil, localeIdentifier: "en-US", speechRate: 1)
        }
        let speaker = PetStandaloneSpeaker()
        let playback = PetSpeechPlaybackSignal()
        speaker.speechPlayback = playback
        var failure: String?
        var renderedSpeech = false
        speaker.onFailure = { failure = $0 }
        defer { speaker.teardown() }
        let warmup = Task { await synthesizer.warmUp() }
        speaker.speak(text: "This preview will be replaced.", synthesizer: synthesizer)
        try await Task.sleep(for: .milliseconds(100))
        speaker.speak(text: "Voice preview is working.", synthesizer: synthesizer)
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while speaker.isSpeaking && ContinuousClock.now < deadline {
            if playback.envelope.level() > 0 { renderedSpeech = true }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(failure == nil)
        #expect(renderedSpeech)
        #expect(!speaker.isSpeaking)
        await warmup.value
        await synthesizer.shutdown()
    }

    @Test("Speech resampling preserves waveform and duration across callback boundaries")
    func streamingSpeechResampling() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let total = 44_100
        func buffer(start: Int, count: Int) throws -> AVAudioPCMBuffer {
            let result = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            result.frameLength = AVAudioFrameCount(count)
            let samples = try #require(result.floatChannelData?[0])
            for i in 0..<count {
                samples[i] = Float(sin(2 * .pi * 440 * Double(start + i) / 44_100)) * 0.4
            }
            return result
        }
        let referenceConverter = PetSpeechPCMConverter()
        let reference = try referenceConverter.convert(buffer(start: 0, count: total)) + referenceConverter.finish()
        let streamingConverter = PetSpeechPCMConverter()
        var streamed: [VoiceAudioFrame] = []
        var offset = 0
        while offset < total {
            let count = min(997, total - offset)
            streamed += try streamingConverter.convert(buffer(start: offset, count: count))
            offset += count
        }
        streamed += try streamingConverter.finish()
        let expected = reference.reduce(into: Data()) { $0.append($1.data) }
        let actual = streamed.reduce(into: Data()) { $0.append($1.data) }
        #expect(abs(actual.count / 2 - 24_000) <= 2)
        #expect(actual.count == expected.count)
        let expectedSamples = expected.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let actualSamples = actual.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let squaredError = zip(actualSamples, expectedSamples).reduce(0.0) { sum, pair in
            let difference = Double(pair.0) - Double(pair.1)
            return sum + difference * difference
        }
        #expect(sqrt(squaredError / Double(max(1, actualSamples.count))) < 2)
        #expect(try streamingConverter.finish().isEmpty)
    }

    @Test("PetState resolves motion and mood across voice statuses and drag walking")
    func petStateResolution() {
        var state = PetState()
        #expect(state.resolvedMotion == .idle)
        #expect(state.resolvedMood == .neutral)

        state.status = .listening
        #expect(state.resolvedMotion == .waiting)
        #expect(state.resolvedMood == .curious)

        state.status = .working
        #expect(state.resolvedMotion == .working)
        #expect(state.resolvedMood == .focused)

        state.status = .speaking
        #expect(state.resolvedMotion == .waving)
        #expect(state.resolvedMood == .happy)

        state.status = .celebrating
        #expect(state.resolvedMotion == .celebration)
        #expect(state.resolvedMood == .happy)

        state.status = .failed
        #expect(state.resolvedMotion == .failure)
        #expect(state.resolvedMood == .concerned)

        // Walking while dragging overrides status motion
        state.isWalking = true
        #expect(state.resolvedMotion == .walking)
    }

    @Test("Ambient pet gestures vary without repetition and settle at neutral")
    func ambientGestures() {
        for status in PetStatus.allCases {
            let choices = PetGesture.choices(for: status, excluding: nil)
            if [.idle, .thinking, .working, .speaking].contains(status) {
                #expect(choices.count >= 4)
                for previous in choices {
                    let next = PetGesture.choices(for: status, excluding: previous)
                    #expect(!next.contains(previous))
                    #expect(!next.isEmpty)
                }
            } else {
                #expect(choices.isEmpty)
            }
        }
        #expect(PetGesture.restRange(for: .idle).upperBound <= 6)
        #expect(PetGesture.restRange(for: .speaking).upperBound <= 3)
        // Distinct choreography must remain distinct, even when sharing an atlas row.
        let signatures = PetGesture.allCases.map { gesture in
            [0.2, 0.4, 0.6, 0.8].flatMap { fraction -> [Int] in
                let pose = gesture.pose(at: gesture.duration * fraction)
                return [pose.x, pose.y, pose.rotation, pose.scaleX, pose.scaleY]
                    .map { Int(($0 * 10_000).rounded()) }
            }
        }
        #expect(Set(signatures).count == PetGesture.allCases.count)
        #expect(!PetGesture.choices(for: .working, excluding: nil).contains(.greet))
        #expect(!PetGesture.choices(for: .working, excluding: nil).contains(.hop))
        for gesture in PetGesture.allCases {
            for elapsed in [-1.0, 0, gesture.duration, gesture.duration * 10] {
                let pose = gesture.pose(at: elapsed)
                #expect(abs(pose.x) < 0.0001)
                #expect(abs(pose.y) < 0.0001)
                #expect(abs(pose.rotation) < 0.0001)
                #expect(abs(pose.scaleX - 1) < 0.0001)
                #expect(abs(pose.scaleY - 1) < 0.0001)
            }
            let poses = (1...8).map { gesture.pose(at: gesture.duration * Double($0) / 10) }
            #expect(poses.contains { abs($0.x) + abs($0.y) + abs($0.rotation) + abs($0.scaleY - 1) > 0.001 })
        }
    }

    @Test("PetSpriteCache decodes all four RxBuddy sheets and settles after one playback")
    @MainActor
    func spriteAtlasDecodingAndFrameTiming() throws {
        let character = PetCharacter.rxcodeBuddy
        let atlas = try #require(PetSpriteCache.shared.atlas(for: character))

        #expect(atlas.frames.count == 8)
        #expect(character.additionalSpriteSheetURLs.count == 3)
        for row in atlas.frames {
            #expect(row.count == 24)
        }
        #expect(atlas.manifest.frameWidth == 256)
        #expect(atlas.manifest.frameHeight == 256)
        #expect(atlas.manifest.frames.count == 192)
        for row in atlas.frames {
            for frame in row {
                #expect(frame.width == 256)
                #expect(frame.height == 256)
                #expect(frame.alphaInfo != .none)
            }
        }

        let first = PetSpriteCache.shared.frameIndex(for: character, motion: .working, at: 0.01)
        let later = PetSpriteCache.shared.frameIndex(for: character, motion: .working, at: 0.25)
        #expect(first == 0)
        #expect(later > first)
        #expect(later < 24)
        #expect(PetSpriteCache.shared.frameIndex(for: character, motion: .working, at: 0.5) == 6)

        for motion in PetMotion.allCases {
            let duration = PetSpriteCache.shared.animationDuration(for: character, motion: motion)
            #expect(duration > 0)
            #expect(PetSpriteCache.shared.frameIndex(for: character, motion: motion, at: -1) == 0)
            #expect(PetSpriteCache.shared.frameIndex(for: character, motion: motion, at: duration + 0.01) == 23)
            #expect(PetSpriteCache.shared.frameIndex(for: character, motion: motion, at: duration * 100) == 23)
        }
    }

    @Test("SpokenTextChunker strips markdown, code fences, and links without splitting version numbers")
    func spokenTextChunkerSanitizationAndStreaming() {
        let cleaned = SpokenTextChunker.sanitizeForSpeech("""
        ## Status Update
        Shipped **v2.0** in [RxCode](https://github.com/rxtech-lab/rxcode) using `VoiceSession`.
        ```swift
        let hidden = true
        ```
        All 3 tasks are green!
        """)
        #expect(cleaned.contains("Status Update"))
        #expect(cleaned.contains("Shipped v2.0 in RxCode using VoiceSession."))
        #expect(!cleaned.contains("let hidden"))
        #expect(!cleaned.contains("https://"))
        #expect(!cleaned.contains("**"))

        var chunker = SpokenTextChunker(minimumChunkCharacters: 12, softMaximumCharacters: 120)
        let firstPart = chunker.append("Release v2.0 is ready for review. ")
        #expect(firstPart == ["Release v2.0 is ready for review."])

        // Unclosed code fence is held back and stripped on flush
        let midFence = chunker.append("Here is the summary. ```json\n{\"ok\":true}")
        #expect(midFence == ["Here is the summary."])
        let flushed = chunker.flush()
        #expect(flushed.isEmpty)
    }

    @Test("UtteranceDetector detects speech activation, silence completion, and PCM16 RMS")
    func utteranceDetectorLifecycle() {
        // Generate synthetic 16-bit PCM silence and speech frames
        let silenceSamples = [Int16](repeating: 20, count: 1600)
        let silenceData = silenceSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let silenceRMS = UtteranceDetector.rms(pcm16LE: silenceData)
        #expect(silenceRMS < 0.005)

        let loudSamples = [Int16](repeating: 8000, count: 1600)
        let loudData = loudSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let loudRMS = UtteranceDetector.rms(pcm16LE: loudData)
        #expect(loudRMS > 0.2)

        var detector = UtteranceDetector()
        detector.speechActivationDuration = 0.12
        detector.silenceCompletionDuration = 0.30

        #expect(detector.process(rms: silenceRMS, frameDuration: 0.10) == .none)
        #expect(detector.process(rms: loudRMS, frameDuration: 0.08) == .none)
        #expect(detector.process(rms: loudRMS, frameDuration: 0.08) == .speechStarted)
        #expect(detector.isSpeaking)
        #expect(detector.process(rms: loudRMS, frameDuration: 0.10) == .speechContinuing)
        #expect(detector.process(rms: silenceRMS, frameDuration: 0.15) == .speechContinuing)
        #expect(detector.process(rms: silenceRMS, frameDuration: 0.20) == .speechEnded)
        #expect(!detector.isSpeaking)
    }

    @Test("CodexConfigOverrideParser extracts bare key=value pairs and appends realtime guards")
    func codexConfigOverrideExtraction() {
        let cliArgs = [
            "-c", "mcp_servers.rxcode-ide.command=\"/usr/bin/nc\"",
            "--disable", "legacy_plugin",
            "-c", "model_reasoning_effort=\"medium\"",
        ]
        let bare = CodexConfigOverrideParser.extractBareOverrides(from: cliArgs)
        #expect(bare.contains("mcp_servers.rxcode-ide.command=\"/usr/bin/nc\""))
        #expect(bare.contains("model_reasoning_effort=\"medium\""))
        #expect(!bare.contains("-c"))
        #expect(!bare.contains("legacy_plugin"))
        #expect(bare.contains("features.computer_use=false"))
        #expect(bare.contains("features.apps=false"))
    }

    @Test("PetDailyReportService formats deterministic spoken and markdown report")
    func dailyReportFormatting() {
        let quietSnapshot = PetDailyReportService.Snapshot(
            workspaceName: "Personal",
            completedTasks: [],
            inProgressTasks: [],
            reviewTasks: [],
            attentionTasks: [],
            recentThreads: [],
            recentBriefings: [],
            scheduledSucceeded: 0,
            scheduledFailed: 0,
            activeJobsCount: 0,
            ciFailing: false
        )
        let quietReport = PetDailyReportService.formatDeterministicReport(from: quietSnapshot)
        #expect(quietReport.workspaceName == "Personal")
        #expect(quietReport.spokenSummary.contains("Personal"))
        #expect(quietReport.markdownBody.contains("# Daily Workspace Report"))

        let activeSnapshot = PetDailyReportService.Snapshot(
            workspaceName: "RxLab",
            completedTasks: [("RxCode", "Add Codex Realtime voice")],
            inProgressTasks: [("RxCode", "Wire local Kokoro TTS")],
            reviewTasks: [("RxAgentSDK", "Verify WebRTC SDP")],
            attentionTasks: [("RxCode", "Fix flaky UI test", "CI check failed")],
            recentThreads: [("RxCode", "Pet sprite sheet design", "Codex")],
            recentBriefings: ["v2.0 Voice Architecture"],
            scheduledSucceeded: 2,
            scheduledFailed: 1,
            activeJobsCount: 1,
            ciFailing: true
        )
        let activeReport = PetDailyReportService.formatDeterministicReport(from: activeSnapshot)
        #expect(activeReport.completedTasksCount == 1)
        #expect(activeReport.inProgressTasksCount == 1)
        #expect(activeReport.pendingReviewTasksCount == 1)
        #expect(activeReport.activeThreadsCount == 1)
        #expect(activeReport.ciFailing)
        #expect(activeReport.spokenSummary.contains("CI"))
        #expect(activeReport.markdownBody.contains("Add Codex Realtime voice"))
    }

    @MainActor
    @Test("The pet reports a persisted ready plan once, including its planned feature")
    func dailyReportIncludesReadyPlan() async throws {
        let state = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        state.threadStore = .inMemory()
        let project = Project(name: "Reader", path: "/tmp")
        state.projects = [project]
        let planner = AgentModel(provider: .codex, id: "planner", displayName: "Planner")
        var plan = CodingPlan(id: UUID(), goal: "Add reading lists", source: "",
                              configuration: .init(planner: planner, reviewers: []))
        plan.finish(.draft, text: "Draft design")
        plan.finish(.reconcile, text: "## Features\nPin a reading list to the sidebar.")
        let session = ChatSession(id: plan.id.uuidString, projectId: project.id, title: plan.goal, messages: [])
        state.threadStore.upsert(session.summary)
        try state.threadStore.saveCodingPlan(plan)

        let snapshot = await PetDailyReportService.captureSnapshot(from: state, now: .now.addingTimeInterval(172_800))
        let report = PetDailyReportService.formatDeterministicReport(from: snapshot)
        #expect(snapshot.plans.count == 1)
        #expect(report.completedTasksCount == 0)
        #expect(report.markdownBody.contains("### Unimplemented (1)"))
        #expect(report.markdownBody.contains("**[Reader] Add reading lists** — Ready"))
        #expect(report.markdownBody.contains("Pin a reading list to the sidebar."))
        #expect(report.markdownBody.contains("v2 · Host plan"))
        #expect(report.markdownBody.contains(plan.id.uuidString))
        #expect(report.spokenSummary.contains("unimplemented"))
        #expect(!report.spokenSummary.contains("Everything is quiet"))
    }

    @Test("Voice seeds survive persistence and legacy preferences retain their agent")
    func voiceSeedCompatibility() throws {
        var cfg = PetConfiguration()
        cfg.voiceMode = .codexRealtime
        cfg.customAgent = TaskAgentConfig(provider: .codex, model: "gpt-5")
        cfg.localTTSSeed = 1234
        let data = try JSONEncoder().encode(cfg)
        let restored = try JSONDecoder().decode(PetConfiguration.self, from: data)
        #expect(restored.resolvedLocalTTSSeed == 1234)
        #expect(restored.customAgent == cfg.customAgent)
        #expect(restored.voiceMode == .codexRealtime)

        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "localTTSSeed")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let migrated = try JSONDecoder().decode(PetConfiguration.self, from: legacyData)
        #expect(migrated.resolvedLocalTTSSeed == 42)
        #expect(migrated.customAgent == cfg.customAgent)

        cfg.localTTSSeed = -1
        #expect((0...Int(Int32.max)).contains(cfg.resolvedLocalTTSSeed))
        cfg.localTTSSeed = Int.max
        #expect(cfg.resolvedLocalTTSSeed == Int(Int32.max))
    }

    @Test("PetConfiguration round-trips cleanly through isolated UserDefaults")
    func petConfigurationPersistence() throws {
        let suiteName = "rxcode.pet.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var cfg = PetConfiguration()
        cfg.isEnabled = true
        cfg.voiceMode = .localPipeline
        cfg.codexTransport = .webRTC
        cfg.codexVoice = CodexRealtimeVoicePreset.maple.rawValue
        cfg.localSpeechSource = .appleSpeech
        cfg.customAgent = TaskAgentConfig(provider: .claudeCode, model: "claude-sonnet-4-6")
        cfg.localTTSModelID = "mlx-community/Kokoro-82M-bf16"
        cfg.proactiveMode = .voiceAndBubble
        cfg.dailyReportAutoEnabled = true
        cfg.dailyReportHour = 10
        cfg.dailyReportMinute = 15
        cfg.save(to: defaults)

        let loaded = PetConfiguration.load(from: defaults)
        #expect(loaded == cfg)
    }

    @Test("Codex Realtime v3 voices preserve supported settings and migrate legacy voices")
    func codexRealtimeVoiceCompatibility() throws {
        let supported = [
            "juniper", "maple", "spruce", "ember", "vale", "breeze", "arbor", "sol",
            "cove", "aube", "bubbie", "haetsal", "hanul", "himari", "leher", "miko",
            "neer", "porto", "rindo", "rio", "rivage", "selva", "sonna", "tinta", "viola"
        ]
        #expect(CodexRealtimeVoicePreset.allCases.map(\.rawValue) == supported)
        #expect(PetConfiguration().codexVoice == "juniper")

        let suiteName = "rxcode.pet.voice.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var cfg = PetConfiguration()
        cfg.dailyReportHour = 14
        cfg.customAgent = TaskAgentConfig(provider: .codex, model: "gpt-5")
        for voice in supported + ["marin", "cedar", "alloy", "unknown", ""] {
            cfg.codexVoice = voice
            cfg.save(to: defaults)
            let expected = supported.contains(voice) ? voice : "juniper"
            #expect(cfg.resolvedCodexVoice.rawValue == expected)
            let loaded = PetConfiguration.load(from: defaults)
            #expect(loaded.codexVoice == expected)
            var expectedConfiguration = cfg
            expectedConfiguration.codexVoice = expected
            #expect(loaded == expectedConfiguration)
        }
    }
}
