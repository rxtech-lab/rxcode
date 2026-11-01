import XCTest
import RxAgentCore
import RxAgentHarness
import struct RxCodeCore.VideoGenerationSettings
import struct RxCodeCore.ImageGenerationSettings
import struct RxCodeCore.AudioGenerationSettings
import struct RxCodeCore.DecisionRequest
import struct RxCodeCore.DecisionResult
import struct RxCodeCore.LocalStudioPreferences
import enum RxCodeCore.LocalStudioKind
@testable import RxCode

/// Image, audio and decision studios: prompt parsing, the setup agent's
/// answers, engine arguments and the decision readout.
final class LocalStudioBackendTests: XCTestCase {
    private func model(_ repo: String, _ file: String, task: String?, tags: [String] = []) -> LocalModelInfo {
        var model = LocalModelInfo(repoID: repo, author: "a", files: [file], sizeBytes: 1, parameterCount: nil,
            contextLength: nil, architecture: nil, quantization: nil, downloadedAt: Date())
        model.huggingFaceMetadata = HFModelSummary(id: repo, author: "a", downloads: 0, likes: 0, parameterCount: nil,
            contextLength: nil, architecture: nil, lastModified: nil, pipelineTag: task, tags: tags)
        return model
    }

    func testStudioPromptsSeparateTextFromAttachments() {
        let prompt = LocalStudioPrompt("[Attached image: /tmp/a b.png]\n[Attached file: /tmp/talk.m4a]\n[Pasted text:\nline one\nline two\n]\n[Link: https://x.y]\n\nmake it dusk")
        XCTAssertEqual(prompt.text, "make it dusk")
        XCTAssertEqual(prompt.files, ["/tmp/a b.png", "/tmp/talk.m4a"])
        XCTAssertEqual(prompt.images, ["/tmp/a b.png"])
        XCTAssertEqual(prompt.audio, ["/tmp/talk.m4a"])
        XCTAssertEqual(prompt.pastedTexts, ["line one\nline two"])
        // The stand-in for an attachment-only message is not a prompt.
        XCTAssertEqual(LocalStudioPrompt("[Attached file: /tmp/a.wav]\n\nSee attached files").text, "")
        XCTAssertEqual(LocalStudioPrompt("See attached files").text, "See attached files")
    }

    func testStudioModelsTurnAMessageIntoTheirTool() throws {
        for (kind, name) in [(LocalStudioKind.image, "ImageGeneration"), (.audio, "AudioGeneration"), (.decision, "Decision")] {
            let request = HarnessModelRequest(model: "m", system: "", messages: [.user("a lighthouse")])
            let chunks = LocalStudioHarnessModel.reply(to: request, modelID: "repo/x.gguf", kind: kind)
            guard case .toolCall(let call) = chunks.first else { return XCTFail("\(kind): \(chunks)") }
            XCTAssertEqual(call.name, name)
            XCTAssertEqual(try XCTUnwrap(call.arguments?.objectValue)["model"], .string("repo/x.gguf"))
        }
        // Transcription runs on an attachment alone; other studios ask for text.
        let audioOnly = HarnessModelRequest(model: "m", system: "", messages: [.user("[Attached file: /tmp/a.wav]\n\nSee attached files")])
        guard case .toolCall = LocalStudioHarnessModel.reply(to: audioOnly, modelID: "m", kind: .audio).first else { return XCTFail() }
        guard case .textDelta = LocalStudioHarnessModel.reply(to: audioOnly, modelID: "m", kind: .image).first else { return XCTFail() }
    }

    func testImageFollowUpsUseLatestSuccessfulImage() throws {
        let history: [HarnessMessage] = [
            .user("happy snowman"),
            .toolResult(callID: "first", name: "ImageGeneration", text: #"{"savedPath":"/tmp/snowman.png"}"#),
            .user("make it cartoon like"),
            .toolResult(callID: "second", name: "ImageGeneration", text: #"{"savedPath":"/tmp/cartoon snowman.png"}"#),
            .toolResult(callID: "failed", name: "ImageGeneration", text: #"{"savedPath":"/tmp/failed.png"}"#, isError: true),
            .toolResult(callID: "video", name: "VideoGeneration", text: #"{"savedPath":"/tmp/video.mp4"}"#),
        ]
        func prompt(_ text: String, history: [HarnessMessage], kind: LocalStudioKind = .image) throws -> LocalStudioPrompt {
            let request = HarnessModelRequest(model: "m", system: "", messages: history + [.user(text)])
            let chunks = LocalStudioHarnessModel.reply(to: request, modelID: "m", kind: kind)
            guard case .toolCall(let call) = chunks.first else {
                throw NSError(domain: "Expected studio tool call", code: 1)
            }
            return LocalStudioPrompt(try XCTUnwrap(call.arguments?.objectValue?["prompt"]?.stringValue))
        }
        let followUp = try prompt("add a scarf", history: history)
        XCTAssertEqual(followUp.text, "add a scarf")
        XCTAssertEqual(followUp.images, ["/tmp/cartoon snowman.png"])
        XCTAssertEqual(try prompt("make it cartoon like", history: Array(history.prefix(2))).images, ["/tmp/snowman.png"])
        XCTAssertEqual(try prompt("[Attached image: /tmp/override.png]\nedit this", history: history).images, ["/tmp/override.png"])
        XCTAssertTrue(try prompt("new image", history: []).images.isEmpty)
        XCTAssertTrue(try prompt("new video", history: history, kind: .video).images.isEmpty)
    }

    func testChatModelsNeverSeeStudioTools() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = HarnessModelRequest(model: "m", system: "", messages: [.user("hi")])
        request.tools = (["read"] + LocalStudioKind.toolNames.sorted()).map {
            HarnessToolSpec(name: $0, description: $0, parameters: .object([:]))
        }
        XCTAssertEqual(LocalModelContext.studioToolNames, LocalStudioKind.toolNames)
        XCTAssertEqual(try LocalModelContext.compact(request, directory: directory).tools.map(\.name), ["read"])
    }

    func testModelsOpenInTheirStudioAndPickAnEngine() {
        let image = model("city96/FLUX.1-schnell-gguf", "flux1-schnell-Q4_K_S.gguf", task: "text-to-image")
        let speech = model("OuteAI/OuteTTS-0.2-500M-GGUF", "OuteTTS-0.2-500M-Q8_0.gguf", task: "text-to-speech")
        let asr = model("ggml-org/ultravox-v0_5-llama-3_2-1b-GGUF", "Llama-3.2-1B-Instruct-Q4_K_M.gguf", task: "audio-text-to-text")
        let decision = model("chaoliangUNSW/Jev-Style-0.8B-Decision-v3-GGUF", "Jev-Style-0.8B-Decision-v3-Q4_K_M.gguf", task: "text-classification")
        XCTAssertEqual([image.studioKind, speech.studioKind, asr.studioKind, decision.studioKind], [.image, .audio, .audio, .decision])
        XCTAssertEqual(LocalAudioMode(model: speech), .speech)
        XCTAssertEqual(LocalAudioMode(model: asr), .transcription)

        let none = LocalStudioPreferences()
        XCTAssertEqual(LocalGenerationEngine.resolve(for: image, preferences: none), .stableDiffusion)
        XCTAssertEqual(LocalGenerationEngine.resolve(for: speech, preferences: none), .llamaSpeech)
        XCTAssertEqual(LocalGenerationEngine.resolve(for: asr, preferences: none), .llamaAudioInput)
        XCTAssertEqual(LocalGenerationEngine.resolve(for: decision, preferences: none), .llamaVerdict)
        // A remembered engine that can't run the model falls back.
        XCTAssertEqual(LocalGenerationEngine.resolve(for: asr, preferences: LocalStudioPreferences(engineID: "llamaSpeech")), .llamaAudioInput)
        var mlx = decision
        mlx.format = .mlx
        XCTAssertEqual(LocalGenerationEngine.resolve(for: mlx, preferences: none), .mlxVerdict)
        XCTAssertNotNil(LocalGenerationEngine.llamaVerdict.incompatibility(with: mlx))
    }

    func testMLXStudioRoutingAndUnsupportedArchitectures() throws {
        for (repo, task, engine) in [
            ("mlx-community/FLUX.1-schnell-4bit", "text-to-image", LocalGenerationEngine.mlxImage),
            ("mlx-community/Qwen3-TTS-8bit", "text-to-speech", .mlxAudio),
            ("mlx-community/whisper-large-v3", "automatic-speech-recognition", .mlxAudio),
            ("prince-canuma/LTX-2-distilled", "text-to-video", .mlxVideo),
            ("mlx-community/Wan2.2-4bit", "image-to-video", .mlxVideo)
        ] {
            var item = model(repo, "model.safetensors", task: task)
            item.format = .mlx
            XCTAssertEqual(LocalGenerationEngine.resolve(for: item, preferences: .init(engineID: "stableDiffusion")), engine)
        }
        var unsupported = model("test/unknown-image", "model.safetensors", task: "text-to-image")
        unsupported.format = .mlx
        XCTAssertNil(LocalGenerationEngine.resolve(for: unsupported, preferences: .init()))
        XCTAssertNil(MLXStudioMedia.imageFamily(model("test/Qwen-Image-Edit", "model.safetensors", task: "image-to-image")))
    }

    func testMLXImageArgumentsUseSelectedLocalModelAndSettings() throws {
        let item = model("mlx-community/Qwen-Image-4bit", "model.safetensors", task: "text-to-image")
        let family = try XCTUnwrap(MLXStudioMedia.imageFamily(item))
        var settings = ImageGenerationSettings()
        settings.quality = .custom
        settings.steps = 17
        settings.cfgScale = 2.5
        settings.negativePrompt = "blur"
        settings.refineStrength = 0.75
        let args = MLXStudioMedia.imageArguments(family: family, directory: URL(filePath: "/tmp/my model"),
            prompt: "a 'quoted' $prompt", output: URL(filePath: "/tmp/take.png"), settings: settings, seed: 42, source: "/tmp/source.png")
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(value("--model"), "/tmp/my model")
        XCTAssertEqual(value("--prompt"), "a 'quoted' $prompt")
        XCTAssertEqual(value("--steps"), "17")
        XCTAssertEqual(value("--guidance"), "2.5")
        XCTAssertEqual(value("--seed"), "42")
        XCTAssertEqual(value("--negative-prompt"), "blur")
        XCTAssertEqual(value("--image-strength"), "0.25")
    }

    func testQwen21UsesItsProcessorAdapterAndTurboDefaults() throws {
        for repo in ["mflux-community/qwen-image-2-1-turbo-mflux-q4", "test/Qwen-Image-2.1-Turbo"] {
            let item = model(repo, "model.safetensors", task: "text-to-image")
            let family = try XCTUnwrap(MLXStudioMedia.imageFamily(item))
            XCTAssertEqual(family.command, "mflux-generate-qwen-2.1")
            XCTAssertEqual(family.base, "qwen-image-2.1-turbo")
            XCTAssertEqual(family.steps, 8)
            var settings = ImageGenerationSettings()
            settings.quality = .custom
            settings.cfgScale = 4
            let args = MLXStudioMedia.imageArguments(family: family, directory: URL(filePath: "/tmp/model"),
                prompt: "test", output: URL(filePath: "/tmp/image.png"), settings: settings, seed: 42)
            XCTAssertFalse(args.contains("--guidance"), "Turbo requires the runtime's fixed guidance of 1.")
            XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--base-model")) + 1], "qwen-image-2.1-turbo")
        }
        let standard = try XCTUnwrap(MLXStudioMedia.imageFamily(model("test/Qwen-Image-2.1", "model.safetensors", task: "text-to-image")))
        XCTAssertEqual(standard.steps, 40)
        XCTAssertEqual(standard.guidance, 1)
        for repo in ["test/Qwen-Image-2-1-Edit", "test/Qwen-Image-2.1-ControlNet", "test/Qwen-Image-2-0"] {
            XCTAssertNil(MLXStudioMedia.imageFamily(model(repo, "model.safetensors", task: "text-to-image")))
        }
    }

    func testQwen21RefinementUsesReferenceConditionedEditing() throws {
        for repo in ["test/Qwen-Image-2.1", "mflux-community/qwen-image-2-1-turbo-mflux-q4"] {
            let family = try XCTUnwrap(MLXStudioMedia.imageFamily(model(repo, "model.safetensors", task: "text-to-image")))
            XCTAssertEqual(MLXStudioMedia.ImagePlan(family: family, pipeline: .textToImage).command, family.command)
            XCTAssertEqual(MLXStudioMedia.ImagePlan(family: family, pipeline: .instructionEdit).command, "mflux-generate-qwen-2.1-edit")
            var settings = ImageGenerationSettings()
            settings.refineStrength = 0.75
            let args = MLXStudioMedia.imageArguments(family: family, directory: URL(filePath: "/tmp/model"),
                prompt: "cartoon style", output: URL(filePath: "/tmp/refined.png"), settings: settings,
                seed: 42, source: "/tmp/previous.png", pipeline: .instructionEdit)
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
            XCTAssertEqual(value("--image-paths"), "/tmp/previous.png")
            XCTAssertFalse(args.contains("--strength"), "Edits run the full schedule unless the setup agent lowers it.")
            let subtle = MLXStudioMedia.imageArguments(family: family, directory: URL(filePath: "/tmp/model"),
                prompt: "cartoon style", output: URL(filePath: "/tmp/refined.png"), settings: settings,
                seed: 42, source: "/tmp/previous.png", pipeline: .instructionEdit, editStrength: 0.9)
            XCTAssertEqual(subtle[try XCTUnwrap(subtle.firstIndex(of: "--strength")) + 1], "0.9")
            XCTAssertEqual(value("--prompt"), "cartoon style")
            XCTAssertFalse(args.contains("--image-path"))
            XCTAssertFalse(args.contains("--image-strength"))
        }
    }

    func testMLXVideoFrameGridAndImageRequirement() throws {
        let item = model("test/Wan2.2-I2V", "model.safetensors", task: "image-to-video")
        var settings = VideoGenerationSettings()
        settings.frames = 42
        let directory = URL(filePath: "/tmp/local-model")
        XCTAssertThrowsError(try MLXStudioMedia.videoArguments(family: .wan, model: item, directory: directory,
            prompt: LocalStudioPrompt("move"), output: URL(filePath: "/tmp/take.mp4"), settings: settings))
        let args = try MLXStudioMedia.videoArguments(family: .wan, model: item, directory: directory,
            prompt: LocalStudioPrompt("[Attached image: /tmp/source.png]\nmove"), output: URL(filePath: "/tmp/take.mp4"), settings: settings)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--num-frames")) + 1], "41")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--model-dir")) + 1], directory.path)
        XCTAssertFalse(args.contains("--fps"))
    }

    func testMLXAudioRuntimeIncludesKokoroTextProcessing() {
        let requirements = MLXMediaPackage.audio.requirements
        XCTAssertTrue(requirements.contains("mlx-audio==0.6.3"))
        XCTAssertTrue(requirements.contains { $0.hasPrefix("misaki[zh]") })
        XCTAssertTrue(requirements.contains { $0.hasPrefix("en-core-web-sm @ ") })
        XCTAssertFalse(requirements.contains { $0.contains("misaki[en]") }, "The en extra pulls in PyTorch")
    }

    func testMLXAudioErrorsPrintedOnSuccessfulExitAreSurfaced() {
        XCTAssertEqual(MLXStudioMedia.audioEngineError(in: """
            Creating new KokoroPipeline for language: ja
            Import error: Kokoro requires misaki[ja]
            This might be due to incorrect Python path. Check your project structure.
            """), "MLX Audio couldn't generate speech. Kokoro requires misaki[ja]")
        XCTAssertEqual(MLXStudioMedia.audioEngineError(in: "Error loading model: no such voice\n"),
                       "MLX Audio couldn't generate speech. no such voice")
        XCTAssertNil(MLXStudioMedia.audioEngineError(in: "Joining 1 audio files\n"))
    }

    func testSetupAgentAnswersAreParsedAndChecked() throws {
        let reply = """
        Sure: {"status": "Found the encoders", "answer": {"main": "diffusion-model", "companions": [
          {"flag": "--vae", "repo": "black-forest-labs/FLUX.1-schnell", "file": "ae.safetensors"},
          {"flag": "t5xxl", "repo": "city96/t5-v1_1-xxl-encoder-gguf", "file": "t5-v1_1-xxl-encoder-Q5_K_M.gguf"}],
          "cfg_scale": 1, "steps": 4, "sampler": "euler"}}
        """
        guard case .answer(let recipe)? = MediaCompanionResolver.parse(reply)?.step else { return XCTFail() }
        XCTAssertEqual(recipe.mainFlag, "diffusion-model")
        XCTAssertEqual(recipe.companions.map(\.flag), ["vae", "t5xxl"])
        XCTAssertEqual(recipe.steps, 4)

        let listings: [String: [String: Int64]] = [
            "black-forest-labs/FLUX.1-schnell": ["ae.safetensors": 1],
            "city96/t5-v1_1-xxl-encoder-gguf": ["t5-v1_1-xxl-encoder-Q5_K_M.gguf": 1],
        ]
        XCTAssertNil(MediaCompanionResolver.problem(with: recipe, spec: .image, primary: "flux.gguf", listings: listings))
        var badFlag = recipe
        badFlag.companions[0] = .init(flag: "lora-model-dir", repoID: "black-forest-labs/FLUX.1-schnell", file: "ae.safetensors")
        XCTAssertNotNil(MediaCompanionResolver.problem(with: badFlag, spec: .image, primary: "flux.gguf", listings: listings))
        var unseen = recipe
        unseen.companions[1] = .init(flag: "t5xxl", repoID: "city96/t5-v1_1-xxl-encoder-gguf", file: "made-up.gguf")
        XCTAssertNotNil(MediaCompanionResolver.problem(with: unseen, spec: .image, primary: "flux.gguf", listings: listings))
        // Transcription always needs its audio projector.
        let bare = LocalMediaRecipe(mainFlag: "model", companions: [])
        XCTAssertNotNil(MediaCompanionResolver.problem(with: bare, spec: .transcription, primary: "m.gguf", listings: [:]))
        XCTAssertNil(MediaCompanionResolver.problem(with: bare, spec: .speech, primary: "m.gguf", listings: [:]))

        guard case .listFiles("city96/t5-v1_1-xxl-encoder-gguf")? = MediaCompanionResolver.parse(#"{"tool":"list_files","repo":"city96/t5-v1_1-xxl-encoder-gguf"}"#)?.step
        else { return XCTFail() }
        XCTAssertNil(MediaCompanionResolver.parse(#"{"tool":"list_files","repo":"../etc"}"#))
    }

    func testImageArgumentsFollowSettingsAndRefine() {
        let recipe = LocalMediaRecipe(mainFlag: "diffusion-model",
            companions: [.init(flag: "vae", repoID: "r/v", file: "sub/ae.safetensors")], cfgScale: 1, steps: 4, sampler: "euler")
        var settings = ImageGenerationSettings()
        settings.select(.medium)
        settings.negativePrompt = "blurry"
        let directory = URL(filePath: "/m")
        let plain = recipe.imageArguments(model: URL(filePath: "/m/flux.gguf"), directory: directory, prompt: "a cat",
            output: URL(filePath: "/o.png"), settings: settings, seed: 42, refine: nil)
        XCTAssertEqual(Array(plain.prefix(6)), ["--mode", "img_gen", "--diffusion-model", "/m/flux.gguf", "--vae", "/m/ae.safetensors"])
        XCTAssertEqual(plain.value(after: "--steps"), "4")
        XCTAssertEqual(plain.value(after: "--cfg-scale"), "1.00")
        XCTAssertEqual(plain.value(after: "--seed"), "42")
        XCTAssertEqual(plain.value(after: "--negative-prompt"), "blurry")
        XCTAssertEqual(plain.value(after: "--sampling-method"), "euler")
        XCTAssertFalse(plain.contains("--init-img"))

        let refined = recipe.imageArguments(model: URL(filePath: "/m/flux.gguf"), directory: directory, prompt: "at dusk",
            output: URL(filePath: "/o.png"), settings: settings, seed: 1, refine: ("/src.png", 1280, 1024))
        XCTAssertEqual(refined.value(after: "--init-img"), "/src.png")
        XCTAssertEqual(refined.value(after: "--strength"), "0.55")
        XCTAssertEqual(refined.value(after: "--width"), "1280")
        XCTAssertTrue(refined.contains("--vae-tiling"))
    }

    func testAudioArgumentsForSpeechAndTranscription() {
        let recipe = LocalMediaRecipe(mainFlag: "model", companions: [.init(flag: "mmproj", repoID: "r/v", file: "vocoder.gguf")])
        var settings = AudioGenerationSettings()
        settings.voice = "en_female_1"
        settings.language = "en"
        let speech = recipe.speechArguments(model: URL(filePath: "/m/tts.gguf"), directory: URL(filePath: "/m"), text: "Hello",
            output: URL(filePath: "/o.wav"), settings: settings, seed: 3)
        XCTAssertEqual(speech.value(after: "-mm"), "/m/vocoder.gguf")
        XCTAssertEqual(speech.value(after: "-p"), "Hello")
        XCTAssertEqual(speech.value(after: "--tts-voice"), "en_female_1")
        XCTAssertEqual(speech.value(after: "--tts-lang"), "en")
        let transcription = recipe.transcriptionArguments(model: URL(filePath: "/m/asr.gguf"), directory: URL(filePath: "/m"),
            audio: "/a.wav", instruction: "Transcribe.", settings: settings)
        XCTAssertEqual(transcription.value(after: "--mmproj"), "/m/vocoder.gguf")
        XCTAssertEqual(transcription.value(after: "--audio"), "/a.wav")
        XCTAssertEqual(transcription.value(after: "--temp"), "0")
    }

    func testDecisionReadoutConfigAndCalibration() throws {
        let config = #"{"format":"macjev-readout-v1","readout":"verdict","template":"macjev-render-v1","slot_tokens":{"yes":{"text":" yes","id":9542},"no":{"text":" no","id":874},"verdict_slot":{"text":" ->","id":1411}},"temperatures":{"global":0.88,"clamp":[0.3,5.0]}}"#
        let readout = try XCTUnwrap(DecisionReadout.parse(Data(config.utf8)))
        XCTAssertEqual([readout.yesID, readout.noID, readout.slotID], [9542, 874, 1411])
        XCTAssertEqual(readout.temperature, 0.88)
        XCTAssertTrue(readout.isCalibrated)
        XCTAssertNil(DecisionReadout.parse(Data(#"{"format":"other"}"#.utf8)))

        // Matches the reference runtime: softmax(scores / T).
        let probabilities = readout.probabilities([2.553, -2.19, -0.906])
        XCTAssertEqual(probabilities[0], 0.976, accuracy: 0.001)
        XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(DecisionReadout.renderedOptions(DecisionRequest(question: "It rains.")),
                       ["false: no, the statement does not hold", "true: yes, the statement holds"])
        XCTAssertEqual(DecisionReadout.renderedOptions(DecisionRequest(question: "q", options: [.init(name: "a", detail: "x"), .init(name: "b")])),
                       ["a: x", "b"])
    }

    func testNativeDecisionTransportUsesTheSharedVerdictReadout() async throws {
        var scorer = DecisionScorer(baseURL: URL(filePath: "/unused"), readout: DecisionReadout(), contextSize: 2048)
        scorer.nativeTokenize = { text in
            switch text {
            case " yes": return [1000]
            case " no": return [1001]
            case " ->": return [1002]
            default: return text.utf8.map(Int.init)
            }
        }
        scorer.nativeLogits = { tokens in
            XCTAssertEqual(tokens.last, 1002)
            return [1000: 2.0, 1001: -1.0]
        }
        let scores = try await scorer.scores(state: "Evidence", request: DecisionRequest(question: "It rains."))
        XCTAssertEqual(scores, [3, 3])
        XCTAssertEqual(scorer.readout.probabilities(scores), [0.5, 0.5])
        var wrongReadout = DecisionReadout()
        wrongReadout.yesID = 999
        var invalid = DecisionScorer(baseURL: URL(filePath: "/unused"), readout: wrongReadout, contextSize: 2048)
        invalid.nativeTokenize = scorer.nativeTokenize
        invalid.nativeLogits = scorer.nativeLogits
        do {
            _ = try await invalid.scores(state: "Evidence", request: DecisionRequest(question: "It rains."))
            XCTFail("A mismatched pinned token must fail before inference")
        } catch DecisionScorer.ScoreError.tokenizer { }
    }

    func testDecisionStateCombinesContextAndWebResults() {
        XCTAssertEqual(DecisionTool.state(question: "Is it safe?", context: [], sources: []), "Is it safe?")
        let state = DecisionTool.state(question: "q", context: [" notes "], sources: [.init(title: "T", url: "https://e.com", snippet: "S")])
        XCTAssertEqual(state, "notes\n\nWeb search results for \"q\":\n1. T\nS\nhttps://e.com")
    }

    func testWebSearchResultsParse() {
        let html = """
        <div class="result results_links results_links_deep web-result "><a rel="nofollow" class="result__a" href="https://dev.to/a?x=1&amp;y=2">SQLite <b>vs</b> Postgres</a>
        <a class="result__snippet" href="https://dev.to/a">Pick &quot;SQLite&quot; for <b>mobile</b>.</a></div>
        <div class="result result--ad results_links "><a class="result__a" href="https://ads.example">Ad</a></div>
        <div class="result results_links results_links_deep web-result "><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fp&amp;rut=1">Redirected</a></div>
        """
        let results = WebSearchClient.parse(html)
        XCTAssertEqual(results.map(\.url), ["https://dev.to/a?x=1&y=2", "https://example.org/p"])
        XCTAssertEqual(results.first?.title, "SQLite vs Postgres")
        XCTAssertEqual(results.first?.snippet, "Pick \"SQLite\" for mobile.")
    }

    /// Scores against a real `llama-server` running a Jev-Style decision
    /// model. Runs only when `RXCODE_DECISION_SERVER` names its base URL.
    func testDecisionScorerAgainstLiveServer() async throws {
        guard let base = ProcessInfo.processInfo.environment["RXCODE_DECISION_SERVER"], let url = URL(string: base) else {
            throw XCTSkip("Set RXCODE_DECISION_SERVER to a llama-server running a Jev-Style decision model.")
        }
        let config = #"{"format":"macjev-readout-v1","readout":"verdict","slot_tokens":{"yes":{"text":" yes","id":9542},"no":{"text":" no","id":874},"verdict_slot":{"text":" ->","id":1411}},"temperatures":{"global":0.88}}"#
        let scorer = DecisionScorer(baseURL: url, readout: try XCTUnwrap(DecisionReadout.parse(Data(config.utf8))), contextSize: 8192)
        let request = DecisionRequest(question: "Which team should handle this ticket?", options: [
            .init(name: "billing", detail: "payments, invoices, refunds"),
            .init(name: "technical", detail: "bugs and outages"),
            .init(name: "sales", detail: "new purchases"),
        ])
        let charged = scorer.readout.probabilities(try await scorer.scores(state: "I was charged twice for my subscription this month.", request: request))
        XCTAssertEqual(charged.firstIndex(of: charged.max()!), 0, "\(charged)")
        let crash = scorer.readout.probabilities(try await scorer.scores(state: "The app crashes every time I open settings.", request: request))
        XCTAssertEqual(crash.firstIndex(of: crash.max()!), 1, "\(crash)")
        let statement = scorer.readout.probabilities(try await scorer.scores(state: "The film was excellent.",
            request: DecisionRequest(question: "The review is positive.")))
        XCTAssertGreaterThan(statement[1], statement[0], "\(statement)")
    }
}

private extension Array where Element == String {
    func value(after flag: String) -> String? {
        guard let index = firstIndex(of: flag), index + 1 < count else { return nil }
        return self[index + 1]
    }
}
