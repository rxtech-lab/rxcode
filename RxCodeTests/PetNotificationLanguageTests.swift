import Foundation
import Testing
import RxCodeCore
import RxAgentHarness
@testable import RxCode

struct PetNotificationLanguageTests {
    @Test("Notification models persist independently and legacy settings default to Apple Intelligence")
    func notificationModelCompatibility() throws {
        var configuration = PetConfiguration()
        #expect(configuration.notificationAgent == nil)
        configuration.customAgent = TaskAgentConfig(provider: .codex, model: "general-model")
        for provider in [AgentProvider.claudeCode, .codex, .acp, .localAgent] {
            configuration.notificationAgent = TaskAgentConfig(provider: provider, model: "notification-model")
            let data = try JSONEncoder().encode(configuration)
            let restored = try JSONDecoder().decode(PetConfiguration.self, from: data)
            #expect(restored.notificationAgent == configuration.notificationAgent)
            #expect(restored.customAgent == configuration.customAgent)
            var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            legacy.removeValue(forKey: "notificationAgent")
            let migrated = try JSONDecoder().decode(PetConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
            #expect(migrated.notificationAgent == nil)
            #expect(migrated.customAgent == configuration.customAgent)
        }
    }

    @Test("A removed local notification model preserves the original notification")
    @MainActor
    func missingNotificationModel() async throws {
        var configuration = PetConfiguration()
        configuration.notificationAgent = TaskAgentConfig(provider: .localAgent, model: "missing-\(UUID().uuidString)")
        configuration.conversationLanguageIdentifier = "ja-JP"
        let localized = await PetController.localizeNotification(title: "Done", text: "Task finished.", configuration: configuration) {
            try? await LocalAgentBackendFactory.generateTextCompletion(
                prompt: $0, modelID: configuration.notificationAgent?.model, store: .shared
            )
        }
        #expect(localized.title == "Done")
        #expect(localized.text == "Task finished.")
    }

    @Test("Background GGUF notification setup cannot interrupt active inference")
    @MainActor
    func busyLocalNotificationModel() async {
        let manager = LlamaServerManager()
        let model = LocalModelInfo(repoID: "test/chat", author: "test", files: ["model.gguf"],
            sizeBytes: 0, parameterCount: nil, contextLength: 2048, architecture: nil,
            quantization: nil, downloadedAt: Date(), format: .gguf)
        await manager.beginRequest()
        do {
            _ = try await manager.ensureServer(for: model, modelsRoot: URL(filePath: "/tmp"),
                runtime: URL(filePath: "/missing-runtime"), contextSize: 2048, requiresIdle: true)
            Issue.record("A background notification must not replace active local inference")
        } catch HarnessModelError.unavailable(let message) {
            #expect(message.contains("local model is busy"))
        } catch {
            Issue.record("Expected a busy-model failure, received \(error)")
        }
        await manager.endRequest()
    }

    @Test("Voice seeds remain stable across notification utterances and persisted legacy settings")
    func stableNotificationSeed() throws {
        for seed: Int? in [nil, -1, 42, 1234, Int.max] {
            var configuration = PetConfiguration()
            configuration.localTTSSeed = seed
            let expected = seed == nil || seed == -1 ? 42 : min(seed!, Int(Int32.max))
            let restored = try JSONDecoder().decode(
                PetConfiguration.self, from: JSONEncoder().encode(configuration)
            )
            for _ in 0..<20 {
                #expect(configuration.resolvedLocalTTSSeed == expected)
                #expect(restored.resolvedLocalTTSSeed == expected)
            }
        }
    }

    @Test("Conversation language persists, decodes old preferences and reaches voice instructions")
    @MainActor
    func conversationLanguagePersistenceAndInstructions() throws {
        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        var cfg = PetConfiguration()
        cfg.localTTSModelID = "unchanged-voice"
        cfg.conversationLanguageIdentifier = "zh-TW"
        let suiteName = "rxcode.pet.language.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        cfg.save(to: defaults)
        #expect(PetConfiguration.load(from: defaults) == cfg)
        for mode in [PetVoiceModeKind.codexRealtime, .localPipeline] {
            cfg.voiceMode = mode
            let prompt = PetController.buildVoiceSystemInstructions(appState: app, targetProject: nil, configuration: cfg)
            #expect(prompt.contains("Chinese (Traditional) (zh-TW)"))
            #expect(prompt.contains("including notification announcements"))
            #expect(cfg.localTTSModelID == "unchanged-voice")
        }
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cfg)) as? [String: Any])
        legacy.removeValue(forKey: "conversationLanguageIdentifier")
        let restored = try JSONDecoder().decode(PetConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.conversationLanguageIdentifier == nil)
        #expect(restored.conversationLanguageInstruction.isEmpty)
    }

    @Test("Pet notifications translate captions and speech into every selected language")
    @MainActor
    func notificationLanguage() async {
        for language in PetConfiguration.supportedConversationLocales {
            var configuration = PetConfiguration()
            configuration.conversationLanguageIdentifier = language.id
            let localized = await PetController.localizeNotification(
                title: "Approval Needed", text: "RxCode needs your permission to run Bash.",
                configuration: configuration
            ) { prompt in
                #expect(prompt.contains(language.id))
                #expect(prompt.contains("Approval Needed"))
                #expect(prompt.contains("RxCode needs your permission to run Bash."))
                return #"{"title":"承認が必要です","text":"RxCodeでBashを実行するには承認が必要です。"}"#
            }
            #expect(localized.title == "承認が必要です")
            #expect(localized.text == "RxCodeでBashを実行するには承認が必要です。")
            let voicePrompt = PetController.voiceUpdatePrompt(
                ["CI failed."], languageInstruction: configuration.conversationLanguageInstruction
            )
            #expect(voicePrompt.contains(language.id))
        }
    }

    @Test("Automatic language avoids translation and failed translations preserve notifications")
    @MainActor
    func notificationLanguageFallback() async {
        var configuration = PetConfiguration()
        configuration.conversationLanguageIdentifier = nil
        let automatic = await PetController.localizeNotification(
            title: nil, text: "Task finished.", configuration: configuration
        ) { _ in
            Issue.record("Automatic language must not invoke a translation agent")
            return nil
        }
        #expect(automatic.title == nil)
        #expect(automatic.text == "Task finished.")
        configuration.conversationLanguageIdentifier = "zh-TW"
        for result: String? in [nil, "invalid JSON", #"{"title":null,"text":" "}"#] {
            let fallback = await PetController.localizeNotification(
                title: "Approval Needed", text: "Approve Bash.", configuration: configuration
            ) { _ in result }
            #expect(fallback.title == "Approval Needed")
            #expect(fallback.text == "Approve Bash.")
        }
    }

}
