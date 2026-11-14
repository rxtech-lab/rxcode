import Foundation
import RxCodeCore
import XCTest
@testable import RxCode

/// Covers Codex JSON-RPC item/token parsing and end-to-end Codex script-based
/// workspace file change detection across multi-message / parallel `exec-*` turns.
final class CodexTokenUsageTests: XCTestCase {

    func testGeneratedImageOutputPreservesSavedPathWithoutBase64() throws {
        let output = CodexAppServer.imageGenerationOutput(from: [
            "type": .string("imageGeneration"), "savedPath": .string("/tmp/generated image.png"),
            "result": .string("large-image-payload"), "status": .string("completed")
        ])
        let object = try JSONDecoder().decode([String: JSONValue].self, from: Data(output.utf8))
        XCTAssertEqual(object["savedPath"], .string("/tmp/generated image.png"))
        XCTAssertNil(object["result"])
    }

    func testGeneratedImageOutputPersistsBase64WhenNoSavedPathExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("image bytes".utf8)
        let output = CodexAppServer.imageGenerationOutput(from: [
            "type": .string("imageGeneration"), "result": .string(bytes.base64EncodedString()),
            "status": .string("completed")
        ], directory: directory)
        let object = try JSONDecoder().decode([String: JSONValue].self, from: Data(output.utf8))
        guard case .string(let path) = object["savedPath"] else {
            return XCTFail("Expected a saved generated image path")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertNil(object["result"])
    }

    func testFailedImageGenerationPreservesFailureWithoutCreatingAFile() throws {
        let output = CodexAppServer.toolOutput(from: [
            "type": .string("imageGeneration"), "result": .string(""),
            "status": .string("failed"), "failure": .object(["type": .string("usageLimitExceeded")])
        ])
        let object = try JSONDecoder().decode([String: JSONValue].self, from: Data(output.utf8))
        XCTAssertNotNil(object["failure"])
        XCTAssertNil(object["savedPath"])
        XCTAssertNil(object["result"])
    }

    func testCommandExecutionParsingExtractsAggregatedOutputAndIgnoresReasoningItems() async {
        let server = CodexAppServer()
        let execName = await server.toolName(from: [
            "id": .string("exec-1"),
            "type": .string("commandExecution"),
            "command": .string("/bin/zsh -lc 'git status --short'"),
        ])
        let reasoningName = await server.toolName(from: [
            "id": .string("rs_123"),
            "type": .string("reasoning"),
            "summary": .array([.string("Inspecting files")]),
        ])
        XCTAssertEqual(execName, "Bash")
        XCTAssertEqual(reasoningName, "message")

        let rawItem: [String: JSONValue] = [
            "id": .string("exec-1"),
            "type": .string("commandExecution"),
            "command": .string("/bin/zsh -lc 'python3 update.py'"),
            "cwd": .string("/repo"),
            "aggregatedOutput": .string("updated 2 files\n"),
            "status": .string("completed"),
        ]
        XCTAssertEqual(CodexAppServer.toolOutput(from: rawItem), "updated 2 files\n")

        let sanitized = CodexAppServer.sanitizedToolInput(from: rawItem)
        XCTAssertEqual(sanitized["command"], .string("/bin/zsh -lc 'python3 update.py'"))
        XCTAssertEqual(sanitized["cwd"], .string("/repo"))
        XCTAssertNil(sanitized["aggregatedOutput"])
    }

    @MainActor
    func testCodexOverlappingScriptExecutionsAcrossSplitMessagesRecordFileChanges() async throws {
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rxcode-codex-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoURL) }

        try Self.runZsh(
            "git init -q && git config user.email 'test@rxcode.local' && git config user.name 'RxCode Test'",
            cwd: repoURL.path
        )
        let mapsDir = repoURL.appendingPathComponent("src/maps", isDirectory: true)
        try FileManager.default.createDirectory(at: mapsDir, withIntermediateDirectories: true)
        let trackedFile = mapsDir.appendingPathComponent("studio.ts")
        try "export const mapVersion = 1\n".write(to: trackedFile, atomically: true, encoding: .utf8)
        try Self.runZsh("git add . && git commit -m 'seed'", cwd: repoURL.path)

        let appState = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let backend = MockAgentBackend(provider: .codex)
        appState.agentBackendOverrides[.codex] = backend

        let project = Project(name: "MaoStudio", path: repoURL.path)
        appState.projects = [project]

        let codexSessionId = "codex-thread-\(UUID().uuidString)"
        let wrappedPy = """
        /bin/zsh -lc "python3 - <<'PY'
        from pathlib import Path
        Path('src/maps/studio.ts').write_text('export const mapVersion = 2\\n')
        Path('src/maps/generated.ts').write_text('export const generated = true\\n')
        PY"
        """
        let repoPath = repoURL.path

        await backend.enqueueScript([
            .systemInit(sessionId: codexSessionId, delay: 0.01),
            // 1. Start `exec-1` (Codex commandExecution with initially sparse input, populated at completion).
            MockAgentBackend.Step(
                delay: 0.02,
                event: .assistant(AssistantMessage(
                    id: "exec-1",
                    role: "assistant",
                    content: [.toolUse(id: "exec-1", name: "Bash", input: [
                        "type": .string("commandExecution"),
                        "command": .string(wrappedPy),
                        "cwd": .string(repoPath),
                    ])],
                    usage: nil
                ))
            ),
            // 2. Start parallel read-only `exec-2` and complete `exec-2` first -> sets `needsNewMessage = true`.
            MockAgentBackend.Step(
                delay: 0.04,
                event: .assistant(AssistantMessage(
                    id: "exec-2",
                    role: "assistant",
                    content: [.toolUse(id: "exec-2", name: "Bash", input: [
                        "type": .string("commandExecution"),
                        "command": .string("/bin/zsh -lc 'git status --short'"),
                        "cwd": .string(repoPath),
                    ])],
                    usage: nil
                ))
            ),
            MockAgentBackend.Step(
                delay: 0.02,
                event: .user(UserMessage(
                    toolUseId: "exec-2",
                    content: "",
                    isError: false
                ))
            ),
            // 3. Emit assistant commentary AFTER `exec-2` completed -> splits into a NEW `ChatMessage` bubble
            //    while `exec-1` in the EARLIER bubble is still running (`result == nil`)!
            .assistantText("Updating studio maps via Python script…", delay: 0.04),
            // 4. Execute the actual script mutation on disk while `exec-1` is active, then emit
            //    Codex's completion `toolCallInput` sync + `UserMessage` result for `exec-1`.
            MockAgentBackend.Step(
                delay: 0.05,
                event: .toolCallInput(id: "exec-1", input: [
                    "type": .string("commandExecution"),
                    "command": .string(wrappedPy),
                    "cwd": .string(repoPath),
                    "status": .string("completed"),
                ]),
                sideEffect: {
                    try CodexTokenUsageTests.runZsh(
                        """
                        python3 - <<'PY'
                        from pathlib import Path
                        Path('src/maps/studio.ts').write_text('export const mapVersion = 2\\n')
                        Path('src/maps/generated.ts').write_text('export const generated = true\\n')
                        PY
                        """,
                        cwd: repoPath
                    )
                }
            ),
            MockAgentBackend.Step(
                delay: 0.02,
                event: .user(UserMessage(
                    toolUseId: "exec-1",
                    content: "updated maps\n",
                    isError: false
                ))
            ),
            .assistantText("Done updating maps.", delay: 0.04),
            .result(sessionId: codexSessionId, delay: 0.02),
        ], forCwd: repoPath)

        let outcome = try await appState.sendCrossProject(
            projectId: project.id,
            threadId: nil,
            prompt: "Update mao studio maps",
            agentProvider: .codex,
            waitForResponse: true,
            timeoutSeconds: 15,
            includeIDEMCP: false
        )

        let threadKey = outcome.threadId
        await appState.awaitPendingShellDetections(for: threadKey)

        // Verify ThreadStore recorded both script-modified and script-created files for "This thread".
        let recordedEdits = appState.threadStore.fetchFileEdits(sessionId: threadKey)
        let recordedNames = Set(recordedEdits.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        XCTAssertEqual(recordedNames, ["studio.ts", "generated.ts"])

        let studioEdit = try XCTUnwrap(recordedEdits.first { $0.path.hasSuffix("src/maps/studio.ts") })
        XCTAssertFalse(studioEdit.containsWrite)
        XCTAssertEqual(studioEdit.originalContent, "export const mapVersion = 1\n")
        XCTAssertEqual(studioEdit.modifiedContent, "export const mapVersion = 2\n")

        let generatedEdit = try XCTUnwrap(recordedEdits.first { $0.path.hasSuffix("src/maps/generated.ts") })
        XCTAssertTrue(generatedEdit.containsWrite)
        XCTAssertEqual(generatedEdit.modifiedContent, "export const generated = true\n")

        // Verify `exec-1` survived the mid-turn message split, retained its result, and received inline chat diffs!
        let allTools = (appState.sessionStates[threadKey]?.messages ?? []).flatMap(\.toolCalls)
        let exec1 = try XCTUnwrap(allTools.first { $0.id == "exec-1" })
        XCTAssertEqual(exec1.result, "updated maps\n")
        let inlineChangedNames = Set(exec1.detectedShellFileChanges.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        XCTAssertEqual(inlineChangedNames, ["studio.ts", "generated.ts"])
    }

    private func breakdown(input: Int, cached: Int, output: Int, reasoning: Int = 0) -> JSONValue {
        .object([
            "totalTokens": .number(Double(input + output)),
            "inputTokens": .number(Double(input)),
            "cachedInputTokens": .number(Double(cached)),
            "outputTokens": .number(Double(output)),
            "reasoningOutputTokens": .number(Double(reasoning)),
        ])
    }

    private func params(total: JSONValue, last: JSONValue) -> [String: JSONValue] {
        [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "tokenUsage": .object([
                "total": total,
                "last": last,
                "modelContextWindow": .number(272_000),
            ]),
        ]
    }

    func testBreakdownSplitsCachedInputAndDoesNotDoubleCountReasoning() throws {
        let parsed = try XCTUnwrap(CodexAppServer.tokenUsageBreakdowns(from: params(
            total: breakdown(input: 1_000, cached: 800, output: 150, reasoning: 50),
            last: breakdown(input: 1_000, cached: 800, output: 150, reasoning: 50)
        )))
        XCTAssertEqual(parsed.total.inputTokens, 200)
        XCTAssertEqual(parsed.total.cacheReadInputTokens, 800)
        XCTAssertEqual(parsed.total.outputTokens, 150)
        XCTAssertEqual(parsed.total.cacheCreationInputTokens, 0)
    }

    func testTurnUsageIsDeltaFromPreTurnBaseline() throws {
        // Earlier turns already accrued 5,000 input (4,000 cached) / 300 output.
        let first = try XCTUnwrap(CodexAppServer.tokenUsageBreakdowns(from: params(
            total: breakdown(input: 6_000, cached: 4_500, output: 400),
            last: breakdown(input: 1_000, cached: 500, output: 100)
        )))
        let baseline = try XCTUnwrap(CodexAppServer.usageDelta(from: first.last, to: first.total))
        let second = try XCTUnwrap(CodexAppServer.tokenUsageBreakdowns(from: params(
            total: breakdown(input: 7_500, cached: 5_500, output: 600),
            last: breakdown(input: 1_500, cached: 1_000, output: 200)
        )))

        let turn = try XCTUnwrap(CodexAppServer.usageDelta(from: baseline, to: second.total))
        XCTAssertEqual(turn.inputTokens, 1_000)
        XCTAssertEqual(turn.cacheReadInputTokens, 1_500)
        XCTAssertEqual(turn.outputTokens, 300)
    }

    func testUsageDeltaIsNilWhenNothingAccrued() {
        let usage = CodexAppServer.codexUsageBreakdown([
            "inputTokens": .number(10), "outputTokens": .number(5),
        ])
        XCTAssertNil(CodexAppServer.usageDelta(from: usage, to: usage))
    }

    nonisolated private static func runZsh(_ command: String, cwd: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw NSError(domain: "CodexTokenUsageTests", code: Int(proc.terminationStatus))
        }
    }
}
