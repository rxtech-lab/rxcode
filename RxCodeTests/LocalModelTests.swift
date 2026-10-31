import XCTest
import ImageIO
import AVFoundation
import os
import RxAgentCore
import RxAgentHarness
import struct RxCodeCore.VideoGenerationSettings
@testable import RxCode

final class LocalModelTests: XCTestCase {
    func testHubMetadataPersistsAndClassifiesVideoWithoutGrantingRuntimeSupport() throws {
        var model = LocalModelInfo(repoID: "example/new-video", author: "example", files: ["weights.gguf"],
            sizeBytes: 1, parameterCount: nil, contextLength: nil, architecture: nil,
            quantization: nil, downloadedAt: Date())
        XCTAssertFalse(model.isVideoModel)
        model.huggingFaceMetadata = HFModelSummary(id: model.repoID, author: model.author,
            downloads: 10, likes: 2, parameterCount: nil, contextLength: nil, architecture: nil,
            lastModified: nil, pipelineTag: "text-to-video", libraryName: "diffusers", tags: ["license:apache-2.0"])
        let restored = try JSONDecoder().decode(LocalModelInfo.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored.huggingFaceMetadata, model.huggingFaceMetadata)
        XCTAssertTrue(restored.isVideoModel)
        XCTAssertFalse(LocalVideoRecipe.supports(restored))
        model.huggingFaceMetadata?.pipelineTag = "video-classification"
        XCTAssertFalse(model.isVideoModel)
        model.huggingFaceMetadata = nil
        let legacy = try JSONDecoder().decode(LocalModelInfo.self, from: JSONEncoder().encode(model))
        XCTAssertNil(legacy.huggingFaceMetadata)
        XCTAssertFalse(legacy.isVideoModel)
    }

    func testVideoClassificationDoesNotFallBackToH3Names() {
        var model = LocalModelInfo(repoID: "unsloth/MiniMax-H3-GGUF", author: "unsloth",
            files: ["minimax_h3_ref2va_pruned-Q2_K.gguf"], sizeBytes: 1, parameterCount: nil,
            contextLength: nil, architecture: nil, quantization: nil, downloadedAt: Date())
        XCTAssertTrue(LocalVideoRecipe.supports(model))
        XCTAssertFalse(model.isVideoModel)
        model.huggingFaceMetadata = HFModelSummary(id: model.repoID, author: model.author,
            downloads: 0, likes: 0, parameterCount: nil, contextLength: nil, architecture: nil,
            lastModified: nil)
        XCTAssertFalse(model.isVideoModel)
        model.huggingFaceMetadata?.pipelineTag = "text-to-video"
        XCTAssertTrue(model.isVideoModel)
    }

    func testModelSheetLinksRoundTripAndRejectInvalidTargets() throws {
        for format in LocalModelWeightFormat.allCases {
            let request = LocalModelSheetRequest(repoID: "example/My-Model.v2", format: format)
            XCTAssertEqual(LocalModelSheetRequest.parse(request.url), request)
        }
        for raw in ["https://models/open?repo=a/b&format=gguf",
                    "rxcode://models/delete?repo=a/b&format=gguf",
                    "rxcode://models/open?repo=../b&format=gguf",
                    "rxcode://models/open?repo=a/b/c&format=gguf",
                    "rxcode://models/open?repo=a/b&format=unknown"] {
            XCTAssertNil(LocalModelSheetRequest.parse(try XCTUnwrap(URL(string: raw))))
        }
    }

    func testHuggingFaceCategoryCombinesWithFormatAndAuthor() throws {
        for format in LocalModelWeightFormat.allCases {
            let url = HuggingFaceClient.searchURL("  video  ", format: format, author: "my-account", category: "text-to-video")
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(items.contains(URLQueryItem(name: "filter", value: format.rawValue)))
            XCTAssertTrue(items.contains(URLQueryItem(name: "pipeline_tag", value: "text-to-video")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "author", value: "my-account")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "search", value: "video")))
            XCTAssertEqual(items.filter { $0.name == "pipeline_tag" }.count, 1)
        }
        let all = HuggingFaceClient.searchURL("", format: .mlx)
        let items = try XCTUnwrap(URLComponents(url: all, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertFalse(items.contains { $0.name == "pipeline_tag" })
        XCTAssertFalse(items.contains { $0.name == "search" })
    }

    func testLocalCompactionUsesPreparedPromptAndReservesOutput() throws {
        var request = HarnessModelRequest(model: "local", system: "Instructions", messages: [
            .user("hi"), .assistant("hello"), .user("who are you")
        ])
        XCTAssertNoThrow(try LocalModelContext.checkCompaction(request, promptTokens: 3741, contextSize: 32768))
        XCTAssertThrowsError(try LocalModelContext.checkCompaction(request, promptTokens: 25000, contextSize: 32768))
        request.mode = .generation
        XCTAssertNoThrow(try LocalModelContext.checkCompaction(request, promptTokens: 25000, contextSize: 32768))
    }

    func testLargeToolCatalogDoesNotCompactTwoShortHarnessTurns() async throws {
        let store = InMemoryHarnessSessionStore()
        let agent = HarnessAgent(configuration: await LocalAgentBackendFactory.configuration(store: store))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LocalCompactionProbe(directory: directory)
        for prompt in ["hi", "who are u"] {
            let input = HarnessTurnInput(sessionID: "regression", prompt: prompt, workingDirectory: directory,
                model: model, modelName: "local", extraTools: [LargeCatalogFixtureTool()])
            for try await event in await agent.run(input) {
                if case .compactionStarted = event { XCTFail("Short prepared prompts must not compact") }
                if case .failed(let message) = event { XCTFail(message) }
            }
        }
        let counts = await model.counts()
        XCTAssertEqual(counts.calls, 2)
        XCTAssertGreaterThan(counts.raw, 32768)
        XCTAssertLessThan(counts.prepared, 24576)
        let session = try await store.load(id: "regression")
        XCTAssertNil(session?.summary)
        XCTAssertEqual(session?.compactedThrough, 0)
    }

    func testNativeMLXFullHarnessTwoTurnCache() async throws {
        guard let path = ProcessInfo.processInfo.environment["RXCODE_MLX_SMOKE_DIRECTORY"] else {
            throw XCTSkip("Set TEST_RUNNER_RXCODE_MLX_SMOKE_DIRECTORY to exercise local weights.")
        }
        let directory = URL(filePath: path)
        let model = LocalModelInfo(repoID: directory.lastPathComponent, author: "local", files: ["config.json"],
            sizeBytes: 0, parameterCount: nil, contextLength: 32768, architecture: nil,
            quantization: nil, downloadedAt: Date(), format: .mlx)
        let manager = LlamaServerManager()
        let backend = NativeMLXHarnessModel(manager: manager, model: model,
            modelsRoot: directory.deletingLastPathComponent(), contextWindow: 32768)
        let store = InMemoryHarnessSessionStore()
        var config = await LocalAgentBackendFactory.configuration(store: store)
        config.maxOutputTokens = 256
        config.temperature = 0
        let agent = HarnessAgent(configuration: config)
        do {
            var usage: [UsageInfo] = []
            for prompt in ["hi /no_think", "who are u /no_think"] {
                let input = HarnessTurnInput(sessionID: "live-cache-regression", prompt: prompt,
                    workingDirectory: FileManager.default.temporaryDirectory,
                    model: backend, modelName: model.id, extraTools: [LargeCatalogFixtureTool()])
                for try await event in await agent.run(input) {
                    if case .compactionStarted = event { XCTFail("Unexpected compaction") }
                    if case .turnFinished(let result) = event { usage.append(result.usage) }
                    if case .failed(let message) = event { XCTFail(message) }
                }
            }
            XCTAssertEqual(usage.count, 2)
            if usage.count == 2 {
                XCTAssertEqual(usage[0].cacheReadTokens, 0)
                XCTAssertGreaterThan(usage[1].cacheReadTokens, 100)
                print("MLX harness follow-up: cached=\(usage[1].cacheReadTokens) input=\(usage[1].inputTokens)")
            }
            let session = try await store.load(id: "live-cache-regression")
            XCTAssertNil(session?.summary)
            await manager.stop()
        } catch { await manager.stop(); throw error }
    }

    func testModelCardStripsYAMLFrontMatter() {
        XCTAssertEqual(
            HuggingFaceClient.stripFrontMatter("---\nlicense: mit\ntags:\n- gguf\n---\n# Model\nBody"),
            "# Model\nBody"
        )
        XCTAssertEqual(HuggingFaceClient.stripFrontMatter("# Model\n---\nBody"), "# Model\n---\nBody")
        XCTAssertEqual(HuggingFaceClient.stripFrontMatter("---\nunterminated"), "---\nunterminated")
    }

    func testModelCardConvertsInlineHTMLToMarkdown() {
        let card = """
        <p align="center">
          <img src="logo.png" alt="Logo" width="200">
        </p>
        <p align="center">  <a href="https://prismml.com"><b>Website</b></a> &nbsp;|&nbsp; <a href="https://x.dev"><b>Demo &amp; Examples</b></a> </p>

        > \\~9.4x smaller <!-- note -->
        Use `<b>raw</b>` and <think> tags.
        ```html
        <p>kept</p>
        ```
        """
        XCTAssertEqual(ModelCardMarkdown.normalize(card), """
        ![Logo](logo.png)

        [Website](https://prismml.com) | [Demo & Examples](https://x.dev)

        > ~9.4x smaller
        Use `<b>raw</b>` and <think> tags.
        ```html
        <p>kept</p>
        ```
        """)
    }

    func testNativeMLXCacheMatchesOnlyExactTokenPrefixes() {
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2, 3], incoming: [1, 2, 3, 4]), 3)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2, 3], incoming: [1, 2, 3]), 2)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2, 3], incoming: [1, 9, 3]), 1)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2, 3], incoming: [1, 2]), 1)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2], incoming: [9, 2]), 0)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1], incoming: []), 0)
    }

    func testGGUFHeaderFindsArchitectureAfterArraysAndRejectsMissingMetadata() async throws {
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func string(_ value: String) -> Data { le(UInt64(value.utf8.count)) + Data(value.utf8) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var chat = Data("GGUF".utf8) + le(UInt32(3)) + le(UInt64(0)) + le(UInt64(3))
        chat += string("tokenizer.ggml.tokens") + le(UInt32(9)) + le(UInt32(8)) + le(UInt64(2)) + string("a") + string("bc")
        chat += string("general.file_type") + le(UInt32(4)) + le(UInt32(10))
        chat += string("general.architecture") + le(UInt32(8)) + string("qwen3")
        let chatURL = directory.appending(path: "chat.gguf")
        try chat.write(to: chatURL)
        XCTAssertEqual(try GGUFHeader.architecture(of: chatURL), "qwen3")

        // The shape of a diffusion component: tensors but no metadata.
        let weights = Data("GGUF".utf8) + le(UInt32(3)) + le(UInt64(532)) + le(UInt64(0))
        let weightsURL = directory.appending(path: "weights.gguf")
        try weights.write(to: weightsURL)
        XCTAssertNil(try GGUFHeader.architecture(of: weightsURL))

        // The server must refuse it before launching, with a readable message.
        let model = LocalModelInfo(
            repoID: "local/weights", author: "local", files: ["weights.gguf"], sizeBytes: Int64(weights.count),
            parameterCount: nil, contextLength: nil, architecture: nil, quantization: nil, downloadedAt: Date()
        )
        let root = directory.appending(path: "root")
        try FileManager.default.createDirectory(at: model.directory(in: root), withIntermediateDirectories: true)
        try weights.write(to: model.primaryFile(in: root))
        do {
            _ = try await LlamaServerManager().ensureServer(
                for: model, modelsRoot: root, runtime: URL(filePath: "/usr/bin/true"), contextSize: 4096)
            XCTFail("A GGUF without an architecture must not start a server")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no model architecture metadata"), "\(error)")
        }
        let failure = LocalAgentBackendFactory.ResolveFailure(message: "readable")
        XCTAssertEqual(String(describing: failure), "readable")
    }

    func testNativeMLXContextBudgetRejectsOverflowAndCapsOutput() throws {
        XCTAssertEqual(try NativeMLXInference.outputBudget(promptTokens: 100, contextSize: 128, requested: 64), 28)
        XCTAssertEqual(try NativeMLXInference.outputBudget(promptTokens: 100, contextSize: 8192, requested: nil), 4096)
        XCTAssertThrowsError(try NativeMLXInference.outputBudget(promptTokens: 128, contextSize: 128, requested: nil)) {
            guard case HarnessModelError.contextOverflow = $0 else { return XCTFail("Expected context overflow") }
        }
    }

    func testNativeMLXPreservesToolHistoryAndStructuredArguments() throws {
        let request = HarnessModelRequest(model: "local", system: "System", messages: [
            .user("Read the file"),
            .assistant("", toolCalls: [.init(id: "call-1", name: "read", argumentsJSON: "{\"path\":\"a.swift\"}")]),
            .toolResult(callID: "call-1", name: "read", text: "contents"),
        ], tools: [.init(name: "read", description: "Read a file", parameters: .object([
            "type": .string("object"), "required": .array([.string("path")])
        ]))])
        let messages = NativeMLXInference.messages(request)
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0]["content"] as? String, "System")
        let calls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: any Sendable]])
        XCTAssertEqual(calls[0]["id"] as? String, "call-1")
        let function = try XCTUnwrap(calls[0]["function"] as? [String: any Sendable])
        let arguments = try XCTUnwrap(function["arguments"] as? [String: any Sendable])
        XCTAssertEqual(arguments["path"] as? String, "a.swift")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call-1")
        let tool = try XCTUnwrap(NativeMLXInference.toolSpecs(request)[0]["function"] as? [String: any Sendable])
        XCTAssertEqual(tool["name"] as? String, "read")
        let schema = try XCTUnwrap(tool["parameters"] as? [String: any Sendable])
        XCTAssertEqual(schema["required"] as? [String], ["path"])
    }

    func testNativeMLXReasoningAcrossChunkBoundaries() {
        var splitter = NativeMLXThinkingSplitter()
        XCTAssertEqual(splitter.feed("<thi"), [])
        XCTAssertEqual(splitter.feed("nk>reason</th"), [.reasoningDelta("reason")])
        XCTAssertEqual(splitter.feed("ink>answer"), [.textDelta("answer")])
        XCTAssertEqual(splitter.finish(), [])
        XCTAssertEqual(splitter.feed("a<"), [.textDelta("a")])
        XCTAssertEqual(splitter.finish(), [.textDelta("<")])
    }

    func testNativeMLXRuntimeDoesNotRequireAnInstalledExecutable() async throws {
        guard LlamaRuntimeInstaller.isAppleSilicon else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let runtime = try await MLXRuntimeInstaller.install(appSupport: root, onProgress: { _, _ in
            XCTFail("Native MLX must not download a runtime")
        })
        XCTAssertEqual(runtime.version, "Native Swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLlamaRuntimeVersionComparison() {
        XCTAssertTrue(LlamaRuntimeInstaller.isNewer("b12100", than: "b12005"))
        XCTAssertFalse(LlamaRuntimeInstaller.isNewer("b12005", than: "b12005"))
        XCTAssertFalse(LlamaRuntimeInstaller.isNewer("b9999", than: "b12005"))
        XCTAssertFalse(LlamaRuntimeInstaller.isNewer("b12100", than: "homebrew"))
    }

    func testVideoRecipeMatchesMiniMaxDenoisersOnly() throws {
        func model(_ repo: String, _ file: String) -> LocalModelInfo {
            LocalModelInfo(repoID: repo, author: "unsloth", files: [file], sizeBytes: 1, parameterCount: nil,
                           contextLength: nil, architecture: nil, quantization: nil, downloadedAt: Date())
        }
        XCTAssertTrue(LocalVideoRecipe.supports(model("unsloth/MiniMax-H3-GGUF", "minimax_h3_ref2va_pruned-Q2_K.gguf")))
        XCTAssertTrue(LocalVideoRecipe.supports(model("joeygambino/MiniMax-H3-x-Z-Image-GGUF", "MiniMax-H3-fl2va-zs05-Q4_0.gguf")))
        XCTAssertFalse(LocalVideoRecipe.supports(model("unsloth/MiniMax-H3-GGUF", "qwen3vl_32b_minimax_h3-Q2_K_M.gguf")))
        XCTAssertFalse(LocalVideoRecipe.supports(model("Qwen/Qwen3-8B-GGUF", "Qwen3-8B-Q4_K_M.gguf")))
        let small = LocalVideoRecipe(
            textEncoder: .init(repoID: "test/encoder", file: "encoder.gguf"),
            videoVAE: .init(repoID: "test/vae", file: "video.safetensors"),
            audioVAE: .init(repoID: "test/vae", file: "audio.safetensors")
        )
        let directory = URL(filePath: "/models/h3")
        let arguments = small.arguments(denoiser: directory.appending(path: "d.gguf"), directory: directory,
                                        prompt: "a fox", output: URL(filePath: "/out/a.webm"))
        for (flag, value) in [("--mode", "vid_gen"), ("--cfg-scale", "1.0"), ("--backend", "te=cpu"),
                              ("--llm", "/models/h3/encoder.gguf"),
                              ("--audio-vae", "/models/h3/audio.safetensors"),
                              ("--prompt", "a fox"), ("--seed", "-1"), ("--output", "/out/a.webm")] {
            let index = try XCTUnwrap(arguments.firstIndex(of: flag), flag)
            XCTAssertEqual(arguments[index + 1], value, flag)
        }
    }

    func testVideoRecipeUsesSelectedQualitySettings() throws {
        let recipe = LocalVideoRecipe(
            textEncoder: .init(repoID: "test", file: "encoder.gguf"),
            videoVAE: .init(repoID: "test", file: "video.safetensors"),
            audioVAE: .init(repoID: "test", file: "audio.safetensors")
        )
        var settings = VideoGenerationSettings()
        settings.select(.high)
        settings.frames = 49
        settings.fps = 30
        settings.seed = 123
        let arguments = recipe.arguments(denoiser: URL(filePath: "/d.gguf"),
            directory: URL(filePath: "/models"), prompt: "snowman", output: URL(filePath: "/a.avi"),
            settings: settings)
        for (flag, value) in [("--width", "1280"), ("--height", "768"), ("--steps", "24"),
                              ("--video-frames", "49"), ("--fps", "30"), ("--seed", "123")] {
            let index = try XCTUnwrap(arguments.firstIndex(of: flag))
            XCTAssertEqual(arguments[index + 1], value)
        }
    }

    func testVideoFileNamesAndProgressParsing() {
        let date = Date(timeIntervalSince1970: 0)
        let name = LocalVideoHarnessModel.fileName(for: "A red panda, stepping along a log!", date: date)
        XCTAssertTrue(name.hasSuffix("-a-red-panda-stepping.mp4"), name)
        XCTAssertTrue(LocalVideoHarnessModel.fileName(for: "!!!", date: date).hasSuffix("-video.mp4"))

        XCTAssertEqual(StableDiffusionProcess.ProgressReader.step(in: "  |=====>     | 3/4 - 12.34s/it"), "Step 3/4 · 12.34s/it")
        XCTAssertNil(StableDiffusionProcess.ProgressReader.step(in: "[INFO ] loading diffusion model"))

        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let reader = StableDiffusionProcess.ProgressReader { line in lines.withLock { $0.append(line) } }
        // Redraws arrive split across reads and joined by carriage returns.
        reader.consume(Data("|==  | 1/4 - 9.0s/it\r|=== | 1/4 - 9.0s/i".utf8))
        reader.consume(Data("t\r|====| 2/4 - 8.5s/it\n".utf8))
        XCTAssertEqual(lines.withLock { $0 }, ["Step 1/4 · 9.0s/it", "Step 2/4 · 8.5s/it"])

        XCTAssertTrue(GeneratedVideoSheet.canPlay(path: "/tmp/My Clip.mp4"))
        XCTAssertFalse(GeneratedVideoSheet.canPlay(path: "/tmp/notes.md"))
    }

    func testVideoModelTurnsAMessageIntoOneToolCall() throws {
        let request = HarnessModelRequest(model: "m", system: "", messages: [.user("  a fox in snow  ")])
        let chunks = LocalVideoHarnessModel.reply(to: request, modelID: "unsloth/MiniMax-H3-GGUF/x.gguf")
        guard case .toolCall(let call) = chunks.first else { return XCTFail("\(chunks)") }
        XCTAssertEqual(call.name, "VideoGeneration")
        let arguments = try XCTUnwrap(call.arguments?.objectValue)
        XCTAssertEqual(arguments["prompt"], .string("a fox in snow"))
        XCTAssertEqual(arguments["model"], .string("unsloth/MiniMax-H3-GGUF/x.gguf"))
        XCTAssertEqual(chunks.last, .finished(reason: "tool_calls"))

        // The tool's result ends the turn; one-off generation prompts never render.
        let finished = HarnessModelRequest(model: "m", system: "", messages: [
            .user("a fox"), .assistant("", toolCalls: [call]),
            .toolResult(callID: call.id, name: call.name, text: "{}"),
        ])
        XCTAssertEqual(LocalVideoHarnessModel.reply(to: finished, modelID: "m"), [.finished(reason: "stop")])
        var summary = request
        summary.mode = .generation
        XCTAssertEqual(LocalVideoHarnessModel.reply(to: summary, modelID: "m"), [.finished(reason: "stop")])
    }

    func testChatModelsNeverSeeTheVideoTool() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = HarnessModelRequest(model: "m", system: "", messages: [.user("hi")])
        request.tools = [
            HarnessToolSpec(name: "read", description: "Read a file", parameters: .object([:])),
            HarnessToolSpec(name: "VideoGeneration", description: "Video", parameters: .object([:])),
        ]
        let compacted = try LocalModelContext.compact(request, directory: directory)
        XCTAssertEqual(compacted.tools.map(\.name), ["read"])
        XCTAssertFalse(compacted.system.contains("VideoGeneration"))
    }

    func testVideoToolResultsDecodeInTheChatCard() throws {
        let result = VideoGenerationResult(savedPath: "/v/a b.mp4", prompt: "fox", model: "H3", elapsedSeconds: 96, width: 640, height: 384)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["savedPath"] as? String, "/v/a b.mp4")
        XCTAssertEqual(decoded["elapsedSeconds"] as? Int, 96)
        XCTAssertEqual(decoded["width"] as? Int, 640)
        let failure = VideoGenerationTool.failure("Out of memory")
        XCTAssertTrue(failure.isError)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(failure.text.utf8))["displayError"], "Out of memory")
    }

    func testAVIFromStableDiffusionConvertsToPlayableMP4() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A 64×32 red JPEG frame.
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        // sd-cli's layout: hdrl with a video and an audio strl, then movi.
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func chunk(_ id: String, _ body: Data) -> Data {
            Data(id.utf8) + le32(body.count) + body + (body.count % 2 == 1 ? Data([0]) : Data())
        }
        func list(_ type: String, _ body: Data) -> Data { chunk("LIST", Data(type.utf8) + body) }
        func strh(_ type: String, scale: Int, rate: Int) -> Data {
            chunk("strh", Data(type.utf8) + Data(count: 16) + le32(scale) + le32(rate) + Data(count: 24))
        }
        let videoFormat = chunk("strf", le32(40) + le32(64) + le32(32) + Data(count: 28))
        let audioFormat = chunk("strf", le16(1) + le16(2) + le32(32_000) + le32(128_000) + le16(4) + le16(16))
        let hdrl = list("hdrl", chunk("avih", Data(count: 56))
            + list("strl", strh("vids", scale: 1, rate: 24) + videoFormat)
            + list("strl", strh("auds", scale: 1, rate: 32_000) + audioFormat))
        var movi = Data()
        for _ in 0..<12 { movi += chunk("00dc", jpeg as Data) }
        movi += chunk("01wb", Data(count: 32_000 / 2 * 4)) // half a second of silence
        let body = Data("AVI ".utf8) + hdrl + list("movi", movi)
        let avi = directory.appending(path: "clip.avi")
        try (Data("RIFF".utf8) + le32(body.count) + body).write(to: avi)

        let parsed = try AVIToMP4Converter.parse(Data(contentsOf: avi))
        XCTAssertEqual(parsed.jpegFrames.count, 12)
        XCTAssertEqual(parsed.framesPerSecond, 24)
        XCTAssertEqual(parsed.audio, .init(sampleRate: 32_000, channels: 2, bitsPerSample: 16))

        let mp4 = directory.appending(path: "clip.mp4")
        try await AVIToMP4Converter.convert(avi: avi, to: mp4)
        let asset = AVURLAsset(url: mp4)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable)
        let kinds = try await asset.load(.tracks).map(\.mediaType)
        XCTAssertEqual(Set(kinds), [.video, .audio])
        let seconds = try await asset.load(.duration).seconds
        XCTAssertEqual(seconds, 0.5, accuracy: 0.05)
        XCTAssertThrowsError(try AVIToMP4Converter.parse(Data("not a video".utf8)))
    }

    func testStableDiffusionRuntimeVersionsAndAssets() {
        XCTAssertEqual(StableDiffusionRuntimeInstaller.buildNumber("master-1030-0a06712"), 1030)
        XCTAssertTrue(StableDiffusionRuntimeInstaller.isNewer("master-1031-abc1234", than: "master-1030-0a06712"))
        XCTAssertFalse(StableDiffusionRuntimeInstaller.isNewer("master-1030-0a06712", than: "master-1030-0a06712"))
        // Builds past 9999 must not sort as older.
        XCTAssertTrue(StableDiffusionRuntimeInstaller.isNewer("master-10000-abc1234", than: "master-9999-abc1234"))
        XCTAssertFalse(StableDiffusionRuntimeInstaller.isNewer("master-1031-abc1234", than: "homebrew"))
        XCTAssertTrue(StableDiffusionRuntimeInstaller.isMacAsset("sd-master-0a06712-bin-Darwin-macOS-26.6.2-arm64.zip"))
        XCTAssertFalse(StableDiffusionRuntimeInstaller.isMacAsset("sd-master-0a06712-bin-win-cuda12-x64.zip"))
    }

    func testStableDiffusionRuntimeLocatesNewestManagedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for version in ["master-999-aaaaaaa", "master-1030-0a06712"] {
            let binary = StableDiffusionRuntimeInstaller.managedRoot(root).appending(path: "\(version)/sd-cli")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        let runtime = try XCTUnwrap(StableDiffusionRuntimeInstaller.locate(appSupport: root))
        XCTAssertEqual(runtime.version, "master-1030-0a06712")
        XCTAssertTrue(StableDiffusionRuntimeInstaller.isManaged(runtime, appSupport: root))

        try StableDiffusionRuntimeInstaller.removeManaged(appSupport: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: StableDiffusionRuntimeInstaller.managedRoot(root).path))
    }

    func testRemovingManagedLlamaRuntimeLeavesOtherCopies() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = LlamaRuntimeInstaller.managedRoot(root).appending(path: "b12005/build/bin/llama-server")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let managed = LlamaRuntimeInstaller.Runtime(path: binary.path, version: "b12005")
        XCTAssertTrue(LlamaRuntimeInstaller.isManaged(managed, appSupport: root))
        XCTAssertFalse(LlamaRuntimeInstaller.isManaged(.init(path: "/opt/homebrew/bin/llama-server", version: "homebrew"), appSupport: root))

        try LlamaRuntimeInstaller.removeManaged(appSupport: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LlamaRuntimeInstaller.managedRoot(root).path))
        XCTAssertNoThrow(try LlamaRuntimeInstaller.removeManaged(appSupport: root))
    }

    @MainActor
    func testSettingsSavedBeforeMLXToggleStillDecode() throws {
        let data = Data(#"{"idleMinutes":30,"defaultModelID":"a/b"}"#.utf8)
        let settings = try JSONDecoder().decode(LocalModelStore.Settings.self, from: data)
        XCTAssertEqual(settings.idleMinutes, 30)
        XCTAssertEqual(settings.defaultModelID, "a/b")
        XCTAssertFalse(settings.mlxDisabled)
    }

    /// The runtime list shows linked package versions; keep them in step with the lockfile.
    func testBuiltInRuntimeVersionsMatchPackageResolved() throws {
        let resolved = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "RxCode.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        guard let data = try? Data(contentsOf: resolved) else { throw XCTSkip("Package.resolved is not readable from the test host.") }
        let pins = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["pins"] as? [[String: Any]])
        func version(_ identity: String) -> String? {
            (pins.first { $0["identity"] as? String == identity }?["state"] as? [String: Any])?["version"] as? String
        }
        XCTAssertEqual(version("mlx-swift"), LocalRuntimeComponent.mlxSwiftVersion)
        XCTAssertEqual(version("mlx-swift-lm"), LocalRuntimeComponent.mlxSwiftLMVersion)
    }

    /// Opt-in hardware smoke test. Uses existing local weights without downloading them.
    func testNativeMLXInstalledModelSmoke() async throws {
        guard let path = ProcessInfo.processInfo.environment["RXCODE_MLX_SMOKE_DIRECTORY"] else {
            throw XCTSkip("Set TEST_RUNNER_RXCODE_MLX_SMOKE_DIRECTORY when invoking xcodebuild to use local MLX weights.")
        }
        let directory = URL(filePath: path)
        let model = LocalModelInfo(repoID: directory.lastPathComponent, author: "local", files: ["config.json"],
            sizeBytes: 0, parameterCount: nil, contextLength: 2048, architecture: nil,
            quantization: nil, downloadedAt: Date(), format: .mlx)
        let manager = LlamaServerManager()
        let backend = NativeMLXHarnessModel(manager: manager, model: model,
            modelsRoot: directory.deletingLastPathComponent(), contextWindow: 2048)
        do {
            var generated = ""
            var outputTokens = 0
            var initialCacheTokens = 0
            var finished = false
            for try await chunk in backend.send(.init(model: model.id, system: "You are helpful.",
                messages: [.user("Say hello.")], maxOutputTokens: 32, temperature: 0)) {
                switch chunk {
                case .textDelta(let text), .reasoningDelta(let text): generated += text
                case .usage(let usage):
                    outputTokens += usage.outputTokens
                    initialCacheTokens += usage.cacheReadTokens
                case .finished: finished = true
                case .toolCall: XCTFail("Unexpected tool call")
                }
            }
            XCTAssertFalse(generated.isEmpty)
            XCTAssertGreaterThan(outputTokens, 0)
            XCTAssertTrue(finished)
            XCTAssertEqual(initialCacheTokens, 0)
            let followup = HarnessModelRequest(model: model.id, system: "You are helpful.", messages: [
                .user("Say hello."), .assistant(generated), .user("Say goodbye.")
            ], maxOutputTokens: 8, temperature: 0)
            func answer(_ request: HarnessModelRequest) async throws -> (text: String, cached: Int, input: Int) {
                var text = ""
                var cached = 0
                var input = 0
                for try await chunk in backend.send(request) {
                    switch chunk {
                    case .textDelta(let part), .reasoningDelta(let part): text += part
                    case .usage(let usage): cached = usage.cacheReadTokens; input = usage.inputTokens
                    default: break
                    }
                }
                return (text, cached, input)
            }
            _ = try await answer(.init(model: model.id, system: "Summarize a conversation.",
                messages: [.user("A user said hello.")], mode: .generation, maxOutputTokens: 8, temperature: 0))
            let warm = try await answer(followup)
            XCTAssertGreaterThan(warm.cached, 0, "Follow-up must reuse the previous prompt")
            XCTAssertGreaterThan(warm.input, warm.cached)
            // Editing the system prompt must not retain the old system's state.
            var edited = followup
            edited.system = "You are a concise assistant."
            let editedWarm = try await answer(edited)
            XCTAssertLessThan(editedWarm.cached, warm.cached)
            let status = await manager.currentStatus
            XCTAssertEqual(status, .running(modelID: model.id, port: 0, contextSize: 2048))
            let resources = await manager.resourceUsage(modelID: model.id)
            XCTAssertGreaterThan(resources.memory ?? 0, 0)
            await manager.stop()
            let stopped = await manager.currentStatus
            XCTAssertEqual(stopped, .stopped)
            let released = await manager.resourceUsage(modelID: model.id)
            XCTAssertNil(released.memory)
            let cold = try await answer(edited)
            XCTAssertEqual(cold.cached, 0, "Unload must discard prompt state")
            XCTAssertEqual(cold.input, editedWarm.input)
            XCTAssertEqual(cold.text, editedWarm.text, "Cached and uncached evaluation must agree")
            await manager.stop()
        } catch {
            await manager.stop()
            throw error
        }
    }

    func testGPUBufferUsageIncludesOnlyMetalAllocations() {
        let log = """
        load_tensors: Metal model buffer size = 1024.00 MiB
        load_tensors: CPU_Mapped model buffer size = 512.00 MiB
        llama_kv_cache: Metal KV buffer size = 128.50 MiB
        llama_context: Metal compute buffer size = 32.00 MiB
        """
        XCTAssertEqual(LlamaServerManager.gpuBufferBytes(in: log), 1_242_038_272)
        XCTAssertNil(LlamaServerManager.gpuBufferBytes(in: "MLX server ready"))
        XCTAssertNil(LlamaServerManager.gpuBufferBytes(in: "Metal buffer size = invalid MiB"))
    }

    func testLocalContextPreservesContractsAndExternalizesDocumentation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let longText = String(repeating: "Detailed documentation. ", count: 200)
        let schema: JSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("description")]),
            "properties": .object([
                "description": .object([
                    "type": .string("string"), "description": .string(longText),
                    "enum": .array([.string(longText)]),
                ]),
            ]),
        ])
        let input = HarnessModelRequest(model: "local", system: "Keep all instructions", messages: [.user("hi")],
            tools: [.init(name: "test", description: longText, parameters: schema)])
        let output = try LocalModelContext.compact(input, directory: directory)
        XCTAssertEqual(output.system, input.system)
        XCTAssertEqual(output.messages.count, 1)
        XCTAssertEqual(output.tools.map(\.name), ["test"])
        XCTAssertLessThan(output.tools[0].description.count, longText.count)
        XCTAssertEqual(output.tools[0].parameters["required"], schema["required"])
        XCTAssertEqual(output.tools[0].parameters["properties"]?["description"]?["enum"],
                       schema["properties"]?["description"]?["enum"])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let full = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        XCTAssertEqual(full["description"], .string(longText))
        XCTAssertEqual(full["parameters"], schema)

        var discoverable = input
        discoverable.tools.append(.init(name: "read", description: "Read a file", parameters: .object([:])))
        let deferred = try LocalModelContext.compact(discoverable, directory: directory)
        XCTAssertEqual(deferred.tools.map(\.name), ["read"])
        let catalog = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("catalog-") })
        XCTAssertTrue(deferred.system.contains(catalog.lastPathComponent))
        XCTAssertTrue(try String(contentsOf: catalog, encoding: .utf8).contains(file.lastPathComponent))
        XCTAssertTrue(deferred.system.hasPrefix(input.system))
        discoverable.messages.append(.assistant("", toolCalls: [
            .init(id: "read-doc", name: "read", argumentsJSON: "{\"filePath\":\"\(file.path)\"}"),
        ]))
        let activated = try LocalModelContext.compact(discoverable, directory: directory)
        XCTAssertEqual(activated.tools.map(\.name), ["read", "test"])
        XCTAssertEqual(activated.tools[1].parameters, output.tools[0].parameters)
        XCTAssertEqual(activated.system, deferred.system)
    }

    func testSmallServiceToolsDoNotInflateInitialPrompt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = HarnessToolSpec(name: "read", description: "Read a file", parameters: .object([:]))
        let services = (0..<100).map {
            HarnessToolSpec(name: "service_\($0)", description: "Perform a service operation", parameters: .object(["type": .string("object")]))
        }
        let input = HarnessModelRequest(model: "local", system: "Instructions", messages: [.user("hi")], tools: [core] + services)
        let result = try LocalModelContext.compact(input, directory: directory)
        XCTAssertEqual(result.tools, [core])
        XCTAssertLessThan(result.system.count - input.system.count, 1_000)
        XCTAssertFalse(result.system.contains("service_99"))
        let catalog = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("catalog-") })
        let text = try String(contentsOf: catalog, encoding: .utf8)
        XCTAssertTrue(text.contains("service_0:"))
        XCTAssertTrue(text.contains("service_99:"))
        var discovering = input
        discovering.messages.append(.assistant("", toolCalls: [.init(id: "catalog", name: "read", argumentsJSON: catalog.path)]))
        XCTAssertEqual(try LocalModelContext.compact(discovering, directory: directory).tools, [core])
        var reordered = input
        reordered.tools.reverse()
        let reorderedResult = try LocalModelContext.compact(reordered, directory: directory)
        XCTAssertEqual(reorderedResult.system, result.system)
        XCTAssertEqual(reorderedResult.tools, result.tools)
    }

    private let gigabyte: Int64 = 1_073_741_824

    func testQuantizationIsParsedFromFileNames() {
        XCTAssertEqual(LocalModelFormat.quantization(from: "Qwen3-8B-Q4_K_M.gguf"), "Q4_K_M")
        XCTAssertEqual(LocalModelFormat.quantization(from: "gpt-oss-20b-MXFP4.gguf"), "MXFP4")
        XCTAssertEqual(LocalModelFormat.quantization(from: "model-UD-Q4_K_XL.gguf"), "UD-Q4_K_XL")
        XCTAssertEqual(LocalModelFormat.quantization(from: "model-IQ4_XS.gguf"), "IQ4_XS")
        XCTAssertNil(LocalModelFormat.quantization(from: "model.gguf"))
    }

    func testParameterCountsFormatCompactly() {
        XCTAssertEqual(LocalModelFormat.parameters(8_190_735_360), "8.2B")
        XCTAssertEqual(LocalModelFormat.parameters(30_532_122_624), "31B")
        XCTAssertEqual(LocalModelFormat.parameters(600_000_000), "600M")
        XCTAssertNil(LocalModelFormat.parameters(nil))
    }

    func testSplitFilesAreGroupedIntoOneVariant() {
        let variants = HuggingFaceClient.group([
            ("Q4_K_M/model-Q4_K_M-00002-of-00002.gguf", 5),
            ("Q4_K_M/model-Q4_K_M-00001-of-00002.gguf", 10),
            ("model-Q8_0.gguf", 30),
        ])
        XCTAssertEqual(variants.count, 2)
        let split = try? XCTUnwrap(variants.first { $0.files.count == 2 })
        XCTAssertEqual(split?.files.first, "Q4_K_M/model-Q4_K_M-00001-of-00002.gguf")
        XCTAssertEqual(split?.sizeBytes, 15)
        XCTAssertEqual(split?.quantization, "Q4_K_M")
    }

    func testFitScalesWithGPUBudget() {
        let mac = LocalHardwareProfile(chip: "Test", memoryBytes: 32 * gigabyte, gpuBudgetBytes: 24 * gigabyte)
        XCTAssertEqual(mac.fit(forModelBytes: 5 * gigabyte), .recommended)
        XCTAssertEqual(mac.fit(forModelBytes: 17 * gigabyte), .fits)
        XCTAssertEqual(mac.fit(forModelBytes: 20 * gigabyte), .tight)
        XCTAssertEqual(mac.fit(forModelBytes: 40 * gigabyte), .tooLarge)
        XCTAssertTrue(LocalModelFit.tight.needsWarning)
        XCTAssertFalse(LocalModelFit.fits.needsWarning)
        XCTAssertEqual(mac.defaultContextSize, 32_768)
    }

    func testLocalModelPathsAreScopedPerRepo() {
        let model = LocalModelInfo(
            repoID: "Qwen/Qwen3-8B-GGUF", author: "Qwen", files: ["Qwen3-8B-Q4_K_M.gguf"],
            sizeBytes: 1, parameterCount: nil, contextLength: nil, architecture: nil,
            quantization: "Q4_K_M", downloadedAt: Date()
        )
        let root = URL(filePath: "/tmp/models")
        XCTAssertEqual(model.primaryFile(in: root).path, "/tmp/models/Qwen__Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf")
        XCTAssertEqual(model.displayName, "Qwen3-8B · Q4_K_M")
    }

    func testNextPageIsReadFromTheLinkHeader() {
        let header = #"<https://huggingface.co/api/models?filter=mlx&cursor=abc>; rel="next""#
        XCTAssertEqual(HuggingFaceClient.nextPageURL(fromLinkHeader: header)?.absoluteString,
                       "https://huggingface.co/api/models?filter=mlx&cursor=abc")
        XCTAssertNil(HuggingFaceClient.nextPageURL(fromLinkHeader: #"<https://x>; rel="prev""#))
        XCTAssertNil(HuggingFaceClient.nextPageURL(fromLinkHeader: nil))
    }

    func testMLXSummaryReadsSafetensorsAndConfig() throws {
        let summary = try XCTUnwrap(HuggingFaceClient.summary([
            "id": "mlx-community/Qwen3-8B-4bit",
            "author": "mlx-community",
            "downloads": 10,
            "safetensors": ["total": 8_190_735_360],
            "config": ["model_type": "qwen3"],
        ], format: .mlx))
        XCTAssertEqual(summary.format, .mlx)
        XCTAssertEqual(summary.parameterCount, 8_190_735_360)
        XCTAssertEqual(summary.architecture, "qwen3")
    }

    func testMLXFilesSkipDocsAndKeepWeights() {
        let files = HuggingFaceClient.mlxFiles([
            ["type": "file", "path": ".gitattributes", "size": 1],
            ["type": "file", "path": "README.md", "size": 1],
            ["type": "file", "path": "config.json", "size": 2],
            ["type": "file", "path": "model.safetensors", "size": 1, "lfs": ["size": 100]],
            ["type": "directory", "path": "assets"],
        ])
        XCTAssertEqual(files.map(\.path), ["config.json", "model.safetensors"])
        XCTAssertEqual(files.reduce(0) { $0 + $1.size }, 102)
    }

    func testMLXQuantizationAndNames() {
        XCTAssertEqual(LocalModelFormat.mlxQuantization(repoID: "mlx-community/Qwen3-8B-4bit", bits: nil), "4-bit")
        XCTAssertEqual(LocalModelFormat.mlxQuantization(repoID: "mlx-community/Qwen3-8B-bf16", bits: nil), "BF16")
        XCTAssertEqual(LocalModelFormat.mlxQuantization(repoID: "lmstudio-community/Qwen3-8B-MLX", bits: 6), "6-bit")
        let model = LocalModelInfo(
            repoID: "mlx-community/Qwen3-8B-4bit", author: "mlx-community", files: ["config.json", "model.safetensors"],
            sizeBytes: 1, parameterCount: nil, contextLength: nil, architecture: nil,
            quantization: "4-bit", downloadedAt: Date(), format: .mlx
        )
        XCTAssertEqual(model.id, "mlx-community/Qwen3-8B-4bit")
        XCTAssertEqual(model.displayName, "Qwen3-8B-4bit")
        XCTAssertEqual(model.primaryFile(in: URL(filePath: "/tmp/models")).path, "/tmp/models/mlx-community__Qwen3-8B-4bit")
    }

    func testModelsSavedBeforeMLXDecodeAsGGUF() throws {
        let json = #"{"repoID":"Qwen/Qwen3-8B-GGUF","author":"Qwen","files":["a.gguf"],"sizeBytes":1,"downloadedAt":0}"#
        let model = try JSONDecoder().decode(LocalModelInfo.self, from: Data(json.utf8))
        XCTAssertEqual(model.format, .gguf)
    }
}

nonisolated private struct LargeCatalogFixtureTool: HarnessTool {
    let name = "large_service_fixture"
    var description: String { String(repeating: "Long service documentation. ", count: 8000) }
    let parameters: JSONValue = .object(["type": .string("object")])
    func execute(_ input: JSONValue, context: HarnessToolContext) async throws -> HarnessToolOutput {
        throw HarnessModelError.unavailable("This fixture must not be invoked.")
    }
}

private actor LocalCompactionProbe: HarnessModel {
    nonisolated let contextWindow: Int? = 32768
    let directory: URL
    private var calls = 0
    private var raw = 0
    private var prepared = 0
    init(directory: URL) { self.directory = directory }
    func counts() -> (calls: Int, raw: Int, prepared: Int) { (calls, raw, prepared) }
    nonisolated func send(_ request: HarnessModelRequest) -> AsyncThrowingStream<HarnessModelChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let count = try await capture(request)
                    continuation.yield(.textDelta("Hello"))
                    continuation.yield(.usage(.init(inputTokens: count, outputTokens: 1)))
                    continuation.yield(.finished(reason: "stop"))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    private func capture(_ request: HarnessModelRequest) throws -> Int {
        calls += 1
        raw = TokenEstimator.estimate(system: request.system, messages: request.messages, tools: request.tools)
        let actual = try LocalModelContext.compact(request, directory: directory)
        prepared = TokenEstimator.estimate(system: actual.system, messages: actual.messages, tools: actual.tools)
        try LocalModelContext.checkCompaction(actual, promptTokens: prepared, contextSize: 32768)
        return prepared
    }
}
