import XCTest
@testable import RxCodeCore

final class LocalStudioTests: XCTestCase {
    func testPipelineTagsPickTheStudio() {
        XCTAssertEqual(LocalStudioKind.kind(forPipelineTag: "text-to-video"), .video)
        XCTAssertEqual(LocalStudioKind.kind(forPipelineTag: "text-to-image"), .image)
        XCTAssertEqual(LocalStudioKind.kind(forPipelineTag: "image-to-image"), .image)
        XCTAssertEqual(LocalStudioKind.kind(forPipelineTag: "text-to-speech"), .audio)
        XCTAssertEqual(LocalStudioKind.kind(forPipelineTag: "automatic-speech-recognition"), .audio)
        XCTAssertEqual(LocalStudioKind.kind(forPipelineTag: "text-classification"), .decision)
        // Vision-language chat models (JEV-27B-VL) stay chat models.
        XCTAssertEqual(LocalStudioKind.kind(forPipelineTag: "image-text-to-text"), .chat)
        XCTAssertEqual(LocalStudioKind.kind(forPipelineTag: nil), .chat)
        XCTAssertEqual(LocalStudioKind.toolNames, ["VideoGeneration", "ImageGeneration", "AudioGeneration", "Decision"])
        XCTAssertNil(LocalStudioKind.chat.toolName)
    }

    func testPreferencesAreRememberedPerStudio() throws {
        let suite = "LocalStudioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        LocalStudioPreferences(engineID: "stableDiffusion", setupAgent: TaskAgentConfig(provider: .claudeCode, model: "haiku"))
            .save(for: .video, defaults: defaults)
        LocalStudioPreferences(setupAgent: TaskAgentConfig(provider: .codex, model: "gpt-5"))
            .save(for: .audio, defaults: defaults)

        XCTAssertEqual(LocalStudioPreferences.load(for: .video, defaults: defaults).setupAgent?.model, "haiku")
        XCTAssertEqual(LocalStudioPreferences.load(for: .audio, defaults: defaults).setupAgent?.provider, .codex)
        XCTAssertNil(LocalStudioPreferences.load(for: .audio, defaults: defaults).engineID)
        XCTAssertEqual(LocalStudioPreferences.load(for: .image, defaults: defaults), LocalStudioPreferences())
    }

    func testDecisionRequestRoundTripsThroughMessageText() {
        let request = DecisionRequest(question: "Which team should handle this ticket?", options: [
            .init(name: "billing", detail: "payments, invoices, refunds"), .init(name: "technical"),
        ])
        XCTAssertEqual(request.messageText, """
        Which team should handle this ticket?

        Options:
        - billing: payments, invoices, refunds
        - technical
        """)
        XCTAssertEqual(DecisionRequest.parse(request.messageText), request)

        // One option is not a choice: the question is judged true or false.
        let statement = DecisionRequest(question: "  SQLite suits a mobile app.  ", options: [.init(name: "yes")])
        XCTAssertTrue(statement.isStatement)
        XCTAssertEqual(statement.messageText, "SQLite suits a mobile app.")
        XCTAssertEqual(DecisionRequest.parse("Is it raining?"), DecisionRequest(question: "Is it raining?"))
    }

    func testDecisionParsingDropsDuplicatesAndBlankOptions() {
        let parsed = DecisionRequest.parse("Pick one\n\nOptions:\n- a\n-  \n- A: again\n* b: second\nnot an option")
        XCTAssertEqual(parsed.question, "Pick one")
        XCTAssertEqual(parsed.options, [.init(name: "a"), .init(name: "b", detail: "second")])
    }

    func testImagePresetsScaleTheModelsRecommendation() {
        var settings = ImageGenerationSettings()
        settings.select(.high)
        XCTAssertEqual([settings.width, settings.height], [1024, 1024])
        settings.select(.wide)
        XCTAssertEqual([settings.width, settings.height], [1024, 576])
        settings.select(.portrait)
        XCTAssertEqual([settings.width, settings.height], [768, 1024])
        XCTAssertEqual(settings.steps(recommended: 4), 6)
        XCTAssertEqual(settings.cfgScale(recommended: 1), 1)

        settings.select(.custom)
        settings.steps = 30
        settings.cfgScale = 6.5
        XCTAssertEqual(settings.steps(recommended: 4), 30)
        XCTAssertEqual(settings.cfgScale(recommended: 1), 6.5)
        // Custom with no explicit steps still follows the model.
        settings.steps = 0
        XCTAssertEqual(settings.steps(recommended: 8), 16)
    }

    func testImageSettingsValidateAndDecodeTolerantly() {
        var settings = ImageGenerationSettings()
        settings.width = 999
        settings.height = 10
        settings.refineStrength = 3
        settings.cfgScale = 99
        let valid = settings.validated
        XCTAssertEqual([valid.width, valid.height], [960, 256])
        XCTAssertEqual(valid.refineStrength, 1)
        XCTAssertEqual(valid.cfgScale, 30)
        XCTAssertEqual(ImageGenerationSettings.decode(valid.encoded), valid)
        // Saved before aspect and refine existed.
        let legacy = ImageGenerationSettings.decode(#"{"quality":"high","width":1024,"height":1024}"#)
        XCTAssertEqual(legacy.quality, .high)
        XCTAssertEqual(legacy.aspect, .square)
        XCTAssertEqual(legacy.refineStrength, 0.55)
    }

    func testAudioDeliveryPresetsAndValidation() {
        var settings = AudioGenerationSettings()
        settings.select(.steady)
        XCTAssertEqual(settings.temperature, 0.3)
        settings.select(.custom)
        XCTAssertEqual(settings.temperature, 0.3)
        settings.language = " EN "
        settings.maxTokens = 1
        settings.transcriptionInstruction = "   "
        let valid = settings.validated
        XCTAssertEqual(valid.language, "en")
        XCTAssertEqual(valid.maxTokens, 64)
        XCTAssertEqual(valid.transcriptionInstruction, AudioGenerationSettings().transcriptionInstruction)
        XCTAssertEqual(AudioGenerationSettings.decode(valid.encoded), valid)
        XCTAssertEqual(AudioGenerationSettings.decode("nope"), AudioGenerationSettings())
    }

    func testDecisionResultDecodes() {
        let result = DecisionResult(
            question: "q", type: "choice",
            scores: [.init(name: "a", detail: "", probability: 0.9, score: 2.1)],
            answer: "a", sources: [.init(title: "t", url: "https://example.com", snippet: "s")],
            model: "m", elapsedSeconds: 1, calibration: "Calibrated"
        )
        XCTAssertEqual(DecisionResult.decode(result.json), result)
        XCTAssertNil(DecisionResult.decode(#"{"displayError":"x"}"#))
    }
}
