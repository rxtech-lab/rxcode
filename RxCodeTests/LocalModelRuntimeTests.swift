import XCTest
import RxAgentCore
import RxAgentHarness
@testable import RxCode

final class LocalModelRuntimeTests: XCTestCase {
    func testLocalFooterClearsAfterFailedPreparation() async throws {
        let manager = LlamaServerManager()
        let model = LocalModelInfo(repoID: "missing/footer-test", author: "missing", files: ["config.json"],
            sizeBytes: 0, parameterCount: nil, contextLength: 2048, architecture: nil,
            quantization: nil, downloadedAt: Date(), format: .mlx)
        let backend = NativeMLXHarnessModel(manager: manager, model: model,
            modelsRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            contextWindow: 2048)
        let initial = await manager.footerState(modelID: model.id)
        XCTAssertEqual(initial.cached, 0)
        XCTAssertFalse(initial.preparing)
        XCTAssertFalse(initial.canRelease)
        do {
            for try await _ in backend.send(.init(model: model.id, system: "", messages: [.user("Hello")])) {}
            XCTFail("Loading a missing model must fail")
        } catch {
            let footer = await manager.footerState(modelID: model.id)
            XCTAssertEqual(footer.cached, 0)
            XCTAssertFalse(footer.preparing, "Failed loading must clear the footer spinner")
            XCTAssertFalse(footer.canRelease)
            let released = await manager.releaseIfAvailable(modelID: model.id)
            XCTAssertFalse(released)
        }
        await manager.stop()
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
            let footer = await manager.footerState(modelID: model.id)
            XCTAssertEqual(footer.cached, editedWarm.cached)
            XCTAssertFalse(footer.preparing)
            XCTAssertTrue(footer.canRelease)
            let otherModel = await manager.footerState(modelID: "another-model")
            XCTAssertEqual(otherModel.cached, 0)
            XCTAssertFalse(otherModel.canRelease)
            await manager.beginRequest()
            let busyRelease = await manager.releaseIfAvailable(modelID: model.id)
            XCTAssertFalse(busyRelease, "Release must recheck in-flight requests on the actor")
            await manager.endRequest()
            let didRelease = await manager.releaseIfAvailable(modelID: model.id)
            XCTAssertTrue(didRelease)
            let releasedFooter = await manager.footerState(modelID: model.id)
            XCTAssertEqual(releasedFooter.cached, 0)
            XCTAssertFalse(releasedFooter.canRelease)
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
}
