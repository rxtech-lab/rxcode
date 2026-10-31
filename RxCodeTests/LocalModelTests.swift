import XCTest
import RxAgentCore
import RxAgentHarness
@testable import RxCode

final class LocalModelTests: XCTestCase {
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

    func testNativeMLXCacheMatchesOnlyExactTokenPrefixes() {
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2, 3], incoming: [1, 2, 3, 4]), 3)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2, 3], incoming: [1, 2, 3]), 2)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2, 3], incoming: [1, 9, 3]), 1)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2, 3], incoming: [1, 2]), 1)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1, 2], incoming: [9, 2]), 0)
        XCTAssertEqual(NativeMLXPromptCache.reusablePrefix(cached: [1], incoming: []), 0)
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
