import AVFoundation
import Foundation
import RxAgentVoice
import RxAgentCore
import Testing
@testable import RxCode
import RxCodeCore

struct PetLookTests {
    @Test("Identical detailed dogs consolidate without losing selection or customized pets")
    @MainActor
    func consolidateDetailedDog() async throws {
        let suite = "PetDogMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = PetLookStore(defaults: defaults, storageDirectory: folder.appendingPathComponent("installed"))
        let exported = try await store.exportPack(id: "dog-buddy", to: folder)
        var duplicate = try await store.preparePack(at: exported)
        duplicate.name = "Detailed Dog"
        try store.save(duplicate)
        var tinted = duplicate
        tinted.id = UUID().uuidString
        tinted.hue = 90
        try store.save(tinted)
        var different = try #require(PetLook.builtins.first { $0.id == "cat-buddy" })
        different.id = UUID().uuidString
        different.name = "Detailed Dog"
        try store.save(different)
        try store.select(duplicate.id)
        await store.consolidateDetailedDog()
        #expect(store.selectedID == "dog-buddy")
        #expect(!store.looks.contains { $0.id == duplicate.id })
        #expect(store.looks.contains(tinted))
        #expect(store.looks.contains(different))
        #expect(FileManager.default.fileExists(atPath: try #require(duplicate.atlasPath)))
        let restored = PetLookStore(defaults: defaults)
        #expect(restored.selectedID == "dog-buddy")
        #expect(!restored.looks.contains { $0.id == duplicate.id })
    }

    @Test("Looks persist, switch live and preserve the current conversation")
    @MainActor
    func persistenceAndHotSwap() throws {
        let suite = "PetLooks-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = PetController(defaults: defaults)
        controller.chatTranscript = [.init(isUser: true, text: "Make yourself pink")]
        var look = controller.looks.selected
        look.id = UUID().uuidString
        look.name = "My Pink Robot"
        look.hue = 280
        look.accessory = "heart"
        try controller.looks.save(look)
        #expect(controller.character.lookHue == 280)
        #expect(controller.character.lookAccessory == "heart")
        #expect(controller.chatTranscript.count == 1)
        let restored = PetLookStore(defaults: defaults)
        #expect(restored.selected == look)
        try restored.remove(look.id)
        #expect(restored.selectedID == "rxcode-buddy")
        #expect(throws: (any Error).self) { try restored.remove("rxcode-buddy") }
        #expect(throws: (any Error).self) { try restored.select("unknown") }
    }

    @Test("Agent customization creates variants and rejects invalid values atomically")
    @MainActor
    func agentCustomization() async throws {
        let suite = "PetLookTools-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PetLookStore(defaults: defaults)
        _ = try await store.handle(.object(["action": .string("save"), "name": .string("Crowned"),
            "hue": .number(90), "accessory": .string("crown")]))
        #expect(store.looks.count == 5)
        #expect(store.selected.accessory == "crown")
        let selected = store.selectedID
        do {
            _ = try await store.handle(.object(["action": .string("save"), "name": .string("Invalid"), "hue": .number(361)]))
            Issue.record("Invalid hue was accepted")
        } catch { }
        #expect(store.selectedID == selected)
        #expect(store.looks.count == 5)
        #expect(IDEToolRegistry.allTools.contains { $0.name == "ide__pet_look" })
    }

    @Test("Data-only packs are copied to app storage and malformed packs are rejected")
    @MainActor
    func importPack() async throws {
        let suite = "PetLookImport-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        var manifest = PetLook(id: "rxcode-buddy", name: "Imported Robot")
        // Ignore pack-supplied IDs and paths; only atlas.png in the pack is imported.
        manifest.atlasPath = "/untrusted/path.png"
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("look.json"))
        let atlas = try #require(PetCharacter.rxcodeBuddy.spriteSheetURL)
        try FileManager.default.copyItem(at: atlas, to: folder.appendingPathComponent("atlas.png"))
        let store = PetLookStore(defaults: defaults, storageDirectory: folder.appendingPathComponent("installed"))
        try await store.importPack(at: folder)
        let imported = store.selected
        let copiedPath = try #require(imported.atlasPath)
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: copiedPath).deletingLastPathComponent()) }
        #expect(imported.id != manifest.id)
        #expect(copiedPath != manifest.atlasPath)
        #expect(FileManager.default.fileExists(atPath: copiedPath))
        #expect(PetSpriteCache.shared.atlas(for: imported.character) != nil)
        manifest.rows = 0
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("look.json"))
        do {
            try await store.importPack(at: folder)
            Issue.record("Invalid motion grid was accepted")
        } catch { }
        #expect(store.selectedID == imported.id)
    }
}

struct PetLookCreationTests {
    @Test("Draft preparation preserves selection and four-sheet exports round trip")
    @MainActor
    func draftAndExport() async throws {
        let suite = "PetLookDraft-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let pack = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let manifest = PetLook(id: "draft", name: "Four Sheets", sheetCount: 4)
        try JSONEncoder().encode(manifest).write(to: pack.appendingPathComponent("look.json"))
        let original = try #require(PetCharacter.rxcodeBuddy.spriteSheetURL)
        for index in 0..<4 {
            let name = index == 0 ? "atlas.png" : "atlas-\(index + 1).png"
            try FileManager.default.copyItem(at: original, to: pack.appendingPathComponent(name))
        }
        let store = PetLookStore(defaults: defaults, storageDirectory: folder.appendingPathComponent("installed"))
        let selected = store.selectedID
        let draft = try await store.preparePack(at: pack)
        #expect(store.selectedID == selected)
        #expect(!store.looks.contains { $0.id == draft.id })
        #expect(draft.character.additionalSpriteSheetURLs.count == 3)
        let atlas = try #require(PetSpriteCache.shared.atlas(for: draft.character))
        #expect(atlas.frames.count == 8)
        #expect(atlas.frames.allSatisfy { $0.count == 24 })
        try store.save(draft)
        let exported = try await store.exportPack(id: draft.id, to: folder)
        let second = try await store.exportPack(id: draft.id, to: folder)
        #expect(exported != second)
        let portable = try JSONDecoder().decode(PetLook.self, from: Data(contentsOf: exported.appendingPathComponent("look.json")))
        #expect(portable.atlasPath == nil)
        #expect(portable.atlasPaths == nil)
        #expect(portable.preset == nil)
        #expect(portable.sheetCount == 4)
        let imported = try await store.preparePack(at: exported)
        #expect(imported.character.additionalSpriteSheetURLs.count == 3)
        #expect(store.selectedID == draft.id)
        try FileManager.default.removeItem(at: pack.appendingPathComponent("atlas-4.png"))
        do { _ = try await store.preparePack(at: pack); Issue.record("Missing animation sheet accepted") } catch { }
        #expect(store.selectedID == draft.id)
    }

    @Test("Creation replies require an absolute pack path")
    func structuredReply() {
        #expect(PetLookCreationSession.packPath(from: "```json\n{\"path\":\"/tmp/my-pet\"}\n```") == "/tmp/my-pet")
        #expect(PetLookCreationSession.packPath(from: "{\"path\":\"relative\"}") == nil)
        #expect(PetLookCreationSession.packPath(from: "No image tool available") == nil)
    }
}

struct PetPresetTests {
    @Test("Idle choreography mixes poses, tail loops, and back-and-forth rocking")
    func idleChoreographyVariety() {
        let rows: [PetMotion: [TimeInterval]] = [
            .idle: Array(repeating: 0.08, count: 24), .waving: Array(repeating: 0.08, count: 24),
            .resting: Array(repeating: 0.08, count: 24), .waiting: Array(repeating: 0.08, count: 24),
        ]
        var motions = Set<PetMotion>()
        var sawReverse = false
        var sawLoopBack = false
        var previous: PetMotion?
        for index in 0..<40 as Range<UInt64> {
            let bout = PetIdleChoreographer.bout(seed: 42, index: index, sleepy: false, rows: rows, previous: previous)
            #expect(!bout.isEmpty)
            #expect(bout.first?.motion != previous)
            #expect(bout.last?.column == 0)
            #expect(bout.allSatisfy { (0..<24).contains($0.column) && $0.duration > 0 && $0.duration <= 2.5 })
            for (a, b) in zip(bout, bout.dropFirst()) {
                if b.column == a.column - 1 { sawReverse = true }
                if b.column < a.column - 1 { sawLoopBack = true }
            }
            motions.formUnion(bout.map(\.motion))
            previous = bout.last?.motion
        }
        #expect(motions == Set(rows.keys))
        #expect(sawReverse)
        #expect(sawLoopBack)
        #expect(PetIdleChoreographer.bout(seed: 1, index: 0, sleepy: true, rows: rows)
            .allSatisfy { [.resting, .idle].contains($0.motion) })
        #expect(PetIdleChoreographer.bout(seed: 1, index: 0, sleepy: false, rows: [:]).isEmpty)
    }

    @Test("Idle never freezes for every built-in look, awake or asleep")
    @MainActor
    func idleAnimationLoop() throws {
        for look in PetLook.builtins {
            let character = look.character
            #expect(Set(PetSpriteCache.shared.idleRows(for: character).keys) == Set(PetIdleChoreographer.candidateMotions))
            for sleepy in [false, true] {
                let script = PetIdleScript()
                var lastChange: TimeInterval = 0
                var lastFrame: PetIdleStep?
                var longestStill: TimeInterval = 0
                for tick in 0..<(24 * 180) {
                    let elapsed = Double(tick) / 24
                    let step = try #require(script.step(at: elapsed, key: character.id, sleepy: sleepy) {
                        PetSpriteCache.shared.idleRows(for: character)
                    })
                    if step.motion != lastFrame?.motion || step.column != lastFrame?.column {
                        longestStill = max(longestStill, elapsed - lastChange)
                        lastChange = elapsed
                        lastFrame = step
                    }
                }
                #expect(longestStill <= 4.5)
            }
        }
    }

    @Test("Every preset bundles four distinct sheets and 24 frames per pose")
    @MainActor
    func presetAssets() throws {
        #expect(PetLook.builtins.map(\.preset) == ["robot", "dog", "cat", "puff"])
        for look in PetLook.builtins {
            let character = look.character
            #expect(character.additionalSpriteSheetURLs.count == 3)
            let urls = [try #require(character.spriteSheetURL)] + character.additionalSpriteSheetURLs
            let data = try urls.map { try Data(contentsOf: $0) }
            #expect(Set(data).count == 4)
            let atlas = try #require(PetSpriteCache.shared.atlas(for: character))
            #expect(atlas.frames.count == 8)
            #expect(atlas.frames.allSatisfy { $0.count == 24 })
            for motion in PetMotion.allCases where motion != .automatic {
                #expect(PetSpriteCache.shared.frameIndex(for: character, motion: motion, at: 100) == 23)
                let duration = PetSpriteCache.shared.animationDuration(for: character, motion: motion)
                let firstDuration = try #require(atlas.manifest.frames[motion.rowIndex * 24].duration)
                #expect(PetSpriteCache.shared.frameIndex(for: character, motion: motion,
                    at: duration * 4 + firstDuration * 0.5, looping: true) == 0)
                #expect(PetSpriteCache.shared.frameIndex(for: character, motion: motion,
                    at: duration * 4 + firstDuration * 1.5, looping: true) > 0)
            }
        }
    }

    @Test("Bundled look creation skill is available in the installed app")
    func creationSkill() throws {
        let resource = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "PetLookSkill")
            ?? Bundle.main.url(forResource: "SKILL", withExtension: "md")
        #expect(resource != nil)
        #expect(try PetLookSkill.instructions().contains("name: rxcode-pet-look"))
    }
}

struct PetSpeechFrameTests {
    @Test("Every pet pose has aligned transparent open and closed artwork")
    @MainActor
    func everyPetSpeechPairs() throws {
        for look in PetLook.builtins {
            let character = look.character
            #expect(character.closedMouthSheetURLs.count == 4)
            #expect(character.openMouthSheetURLs.count == 4)
            let atlas = try #require(PetSpriteCache.shared.atlas(for: character))
            for row in 0..<8 {
                #expect(atlas.closedFrames[row].count == 24)
                #expect(atlas.openFrames[row].count == 24)
                for col in 0..<24 {
                    let closed = try pixels(atlas.closedFrames[row][col])
                    let open = try pixels(atlas.openFrames[row][col])
                    #expect(closed != open)
                    #expect(closed[3] == 0 && open[3] == 0)
                    let spec = atlas.manifest.frames[row * 24 + col]
                    let mouth = try #require(spec.mouth)
                    let changedRegion = CGRect(x: mouth.x - 3, y: mouth.y - 6,
                        width: mouth.width + 6, height: max(17, mouth.height + 12))
                    let frameWidth = atlas.closedFrames[row][col].width
                    for offset in stride(from: 0, to: closed.count, by: 4) where closed[offset..<(offset + 4)] != open[offset..<(offset + 4)] {
                        let pixel = offset / 4
                        #expect(changedRegion.contains(CGPoint(x: pixel % frameWidth, y: pixel / frameWidth)))
                    }
                }
            }
        }
    }

    @Test("Speech pairs survive pack export, import and missing-pair rejection")
    @MainActor
    func speechPackRoundTrip() async throws {
        let suite = "SpeechPairs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = PetLookStore(defaults: defaults, storageDirectory: root.appendingPathComponent("installed"))
        let exported = try await store.exportPack(id: "rxcode-buddy", to: root)
        let draft = try await store.preparePack(at: exported)
        #expect(draft.hasSpeechFrames == true)
        #expect(draft.character.closedMouthSheetURLs.count == 4)
        #expect(draft.character.openMouthSheetURLs.count == 4)
        let source = try #require(PetSpriteCache.shared.atlas(for: .rxcodeBuddy))
        let imported = try #require(PetSpriteCache.shared.atlas(for: draft.character))
        for row in 0..<8 {
            for col in 0..<24 {
                #expect(try pixels(source.closedFrames[row][col]) == pixels(imported.closedFrames[row][col]))
                #expect(try pixels(source.openFrames[row][col]) == pixels(imported.openFrames[row][col]))
            }
        }
        try FileManager.default.removeItem(at: exported.appendingPathComponent("atlas-3-open.png"))
        do { _ = try await store.preparePack(at: exported); Issue.record("A missing speech sheet was accepted") } catch { }
        #expect(store.selectedID == "rxcode-buddy")
    }

    @Test("Quiet gaps, future audio and muted speech select the closed frame")
    func mouthFollowsPlayback() {
        let envelope = PetSpeechEnvelope()
        envelope.setEnabled(true)
        envelope.append([.init(time: 10, level: 0.8), .init(time: 10.02, level: 0)])
        #expect(!envelope.isMouthOpen(at: 9.99))
        #expect(envelope.isMouthOpen(at: 10.01))
        #expect(envelope.isMouthOpen(at: 10.04))
        #expect(envelope.isMouthOpen(at: 10.07))
        #expect(!envelope.isMouthOpen(at: 10.20))
        envelope.setEnabled(false)
        #expect(!envelope.isMouthOpen(at: 10.01))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data)
        return Data(bytes: bytes, count: context.bytesPerRow * image.height)
    }
}

struct PetMediaSelectionTests {
    @Test("Image, video and audio selections persist independently, including None")
    @MainActor
    func mediaPreferencePersistence() throws {
        let suite = "MediaModels-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = MediaGenerationPreferences(defaults: defaults)
        #expect(preferences.selection(.image) == .codex)
        preferences.selections["image"] = .init(provider: .local, model: "local-image")
        preferences.selections["video"] = .init(provider: .flowcy, model: "cloud-video")
        preferences.selections["audio"] = .init(provider: .flowcy, model: "cloud-audio")
        let restored = MediaGenerationPreferences(defaults: defaults)
        #expect(restored.selection(.image)?.model == "local-image")
        #expect(restored.selection(.video)?.model == "cloud-video")
        #expect(restored.selection(.audio)?.model == "cloud-audio")
        restored.selections["image"] = nil
        #expect(MediaGenerationPreferences(defaults: defaults).selection(.image) == nil)
    }

    @Test("Pasted and attached reference images reach the agent as native images")
    func referenceImageAttachments() throws {
        let bytes = Data([1, 2, 3, 4])
        let image = Attachment(type: .image, name: "reference.webp", path: "/tmp/reference.webp", imageData: bytes)
        let file = Attachment(type: .file, name: "notes.md", path: "/tmp/notes.md")
        let resolved = PetLookCreationSession.agentAttachments([image, file])
        #expect(resolved.count == 2)
        guard case .image(let data, let mime) = resolved[0].kind else { Issue.record("Image became a text-only file path"); return }
        #expect(data == bytes)
        #expect(mime == "image/webp")
        guard case .file(let url) = resolved[1].kind else { Issue.record("File attachment was lost"); return }
        #expect(url.path == "/tmp/notes.md")
    }
}

struct FlowcyMediaTransportTests {
    @Test("Real HTTP media transport preserves auth retries, labels and video job handles",
          .enabled(if: ProcessInfo.processInfo.environment["RXCODE_MEDIA_SIMULATION_URL"] != nil))
    @MainActor
    func simulatedHTTP() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_MEDIA_SIMULATION_URL"])
        let baseURL = try #require(URL(string: address))
        var refreshes: [Bool] = []
        let client = FlowcyMediaClient(baseURL: baseURL) { refresh in
            refreshes.append(refresh)
            return refresh ? "fixture-valid" : "fixture-expired"
        }
        let key = UUID().uuidString
        let body: RxCodeCore.JSONValue = .object(["prompt": .string("a transparent pet"), "model": .string("fixture-image")])
        let image = try await client.request("ai/images", body: body, idempotencyKey: key)
        #expect(text(items(image["images"]).first?["mime_type"]) == "image/png")
        #expect(refreshes == [false, true])
        let signedIn = FlowcyMediaClient(baseURL: baseURL) { _ in "fixture-valid" }
        let observed = try await signedIn.request("simulation/requests/\(key)")
        #expect(items(observed["requests"]).count == 2)
        #expect(items(observed["requests"]).allSatisfy { text($0["key"]) == key })
        let models = try await signedIn.allModels()
        #expect(models.count == 6)
        #expect(models.filter { $0.id == "fixture-image" }.count == 1)
        #expect(models.first { $0.id == "fixture-image" }?.labels == ["chat", "image"])
        let video = try await signedIn.request("ai/videos", body: .object([
            "model": .string("fixture-video"), "prompt": .string("a waving pet"),
            "aspect_ratio": .string("16:9"), "duration_seconds": .number(8), "person_generation": .string("allow_adult")
        ]))
        #expect(text(video["job_id"]) == "flowcy-fixture-video")
        let polled = try await signedIn.request("jobs/flowcy-fixture-video")
        #expect(text(polled["status"]) == "running")
    }

    @Test("Pet speech loads Flowcy voices and decodes the selected provider's audio",
          .enabled(if: ProcessInfo.processInfo.environment["RXCODE_MEDIA_SIMULATION_URL"] != nil))
    @MainActor
    func simulatedPetSpeech() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_MEDIA_SIMULATION_URL"])
        let client = FlowcyMediaClient(baseURL: try #require(URL(string: address))) { _ in "fixture-valid" }
        let models = try await client.allModels(capability: "speech")
        #expect(models.count == 4)
        #expect(models.allSatisfy { $0.labels.contains("audio") })
        let hd = try #require(models.first { $0.id == "azure-hd-tts" })
        #expect(try await client.speechVoices(for: hd).map(\.id) == ["en-US-Ava:DragonHDLatestNeural"])
        let azure = try #require(models.first { $0.id == "azure-neural-tts" })
        let azureVoices = try await client.speechVoices(for: azure)
        #expect(azureVoices.map(\.id) == ["fr-FR-DeniseNeural"])
        let gemini = try #require(models.first { $0.provider == "google" })
        let geminiVoices = try await client.speechVoices(for: gemini)
        let gateway = try #require(models.first { $0.provider == "gateway" })
        let selections = [
            FlowcySpeechSelection(model: azure, voice: try #require(azureVoices.first)),
            FlowcySpeechSelection(model: gemini, voice: try #require(geminiVoices.first { $0.id == "Kore" })),
            FlowcySpeechSelection(model: gateway, voice: .init(id: "fixture-speaker", name: "Fixture Speaker"))
        ]
        for selection in selections {
            var config = PetConfiguration()
            config.localTTSModelID = "missing-local-voice"
            config.flowcyVoice = selection
            let synthesis = config.speechSynthesisConfiguration(client: client)
            let synthesizer = PetLocalSpeechSynthesizer { synthesis }
            var audio = Data()
            for try await frame in try await synthesizer.synthesize("Ready & waiting.") {
                #expect(frame.format == VoicePCMFormat(sampleRate: 24_000, channels: 1))
                audio.append(frame.data)
            }
            #expect(audio.contains { $0 != 0 })
        }
        let chosen = try #require(selections.last)
        for (prompt, message) in [("rate-limit", "Speech allowance reached"), ("missing-audio", "no speech audio")] {
            do {
                _ = try await client.speechFrames(text: prompt, selection: chosen)
                Issue.record("Unexpected speech success for \(prompt)")
            } catch { #expect(error.localizedDescription.contains(message)) }
        }
    }

    @Test("Media allowance errors do not retry and non-JSON failures preserve HTTP status",
          .enabled(if: ProcessInfo.processInfo.environment["RXCODE_MEDIA_SIMULATION_URL"] != nil))
    @MainActor
    func simulatedFailures() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["RXCODE_MEDIA_SIMULATION_URL"])
        let baseURL = try #require(URL(string: address))
        let client = FlowcyMediaClient(baseURL: baseURL) { _ in "fixture-valid" }
        let key = UUID().uuidString
        do {
            _ = try await client.request("ai/images", body: .object(["model": .string("fixture-image"), "prompt": .string("rate-limit")]), idempotencyKey: key)
            Issue.record("A media allowance rejection was accepted")
        } catch { #expect(error.localizedDescription.contains("Media rate limit reached")) }
        let observed = try await client.request("simulation/requests/\(key)")
        #expect(items(observed["requests"]).count == 1)
        do {
            _ = try await client.request("ai/images", body: .object(["model": .string("fixture-image"), "prompt": .string("invalid-provider-response")]))
            Issue.record("A non-JSON provider failure was accepted")
        } catch { #expect(error.localizedDescription.contains("HTTP 502")) }
    }
    private func text(_ value: RxCodeCore.JSONValue?) -> String? {
        guard case .string(let text) = value else { return nil }
        return text
    }

    private func items(_ value: RxCodeCore.JSONValue?) -> [RxCodeCore.JSONValue] {
        guard case .array(let items) = value else { return [] }
        return items
    }

}
