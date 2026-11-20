import RxCodeCore
import RxCodeSync
import XCTest
@testable import RxCode

@MainActor
final class FlowcyMCPTests: XCTestCase {
    func testMobileAllowlistHasNoUnknownOrCredentialOperations() throws {
        let forbidden: Set<String> = ["secretsGetUserKey", "secretsGetBundle", "secretsUpsertFile", "projectSecretsWrite", "docsCreateUploadToken", "releaseInstallToken"]
        for operation in FlowcyTool.operations where operation.route == "mobile" {
            XCTAssertNotNil(AutopilotOp(rawValue: operation.name), operation.name)
            XCTAssertFalse(forbidden.contains(operation.name))
        }
    }

    func testCIProjectionPreservesProgressAndRemovesLogsAndUnrelatedFields() {
        let result = AppState.flowcyCIProjection(.object([
            "runs": .array([.object(["id": .number(1), "status": .string("queued"), "conclusion": .null, "html_url": .string("https://github.com/o/r/actions/runs/1"), "secret": .string("must not leave native service")]),
                            .object(["id": .number(2), "status": .string("in_progress")]),
                            .object(["id": .number(3), "status": .string("completed"), "conclusion": .string("failure")])]),
            "jobs": .array([.object(["id": .number(4), "status": .string("in_progress"), "logs": .string("private")])]),
            "hasMore": .bool(true), "token": .string("private")
        ]))
        guard case .array(let runs)? = result["runs"], case .array(let jobs)? = result["jobs"] else { return XCTFail("Missing collections") }
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.first?["status"], .string("queued"))
        XCTAssertEqual(runs.last?["conclusion"], .string("failure"))
        XCTAssertNil(runs.first?["secret"])
        XCTAssertNil(jobs.first?["logs"])
        XCTAssertNil(result["token"])
        XCTAssertEqual(result["hasMore"], .bool(true))
    }

    func testServiceErrorsDoNotExposeRawBodies() throws {
        let app = AppState(startBackgroundServices: false)
        let result = app.safeFlowcyFailure(AutopilotService.ServiceError.apiError(403, "private-token-value"))
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains("permission_denied"))
        XCTAssertFalse(json.contains("private-token-value"))
        XCTAssertEqual(result["isError"], .bool(true))
    }

    func testCatalogAndUnsupportedOperationsDoNotRequireNetwork() async throws {
        let app = AppState(startBackgroundServices: false)
        let result = try await app.ideHandleToolCall(name: FlowcyTool.catalogName, arguments: .object(["operation": .string("docsGetDocument")]), sessionKey: "test")
        guard case .array(let content)? = result["content"], case .string(let text)? = content.first?["text"] else { return XCTFail("Missing catalog text") }
        XCTAssertTrue(text.contains("currentVersion.content"))
        do {
            _ = try await app.ideHandleToolCall(name: FlowcyTool.catalogName, arguments: .object(["operation": .string("secretsGetBundle")]), sessionKey: "test")
            XCTFail("Credential operation must be rejected")
        } catch let error as IDEToolError {
            guard case .notSupported = error else { return XCTFail("Unexpected error") }
        }
    }
}

@MainActor
final class FlowcyCloudBackendTests: XCTestCase {
    private func backend(token: String, permission: PermissionServer = PermissionServer()) -> FlowcyCloudBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlowcyChatFixture.self]
        return FlowcyCloudBackend(baseURL: FlowcyCloudBackend.productionURL, session: URLSession(configuration: config),
                                  permission: permission) {
            $0 ? token : "expired"
        }
    }

    private func request(model: String? = nil, prompt: String = "Continue", cwd: String = "/project",
                         mode: PermissionMode = .default, history: [ChatMessage] = []) -> BackendSendRequest {
        BackendSendRequest(streamId: UUID(), prompt: prompt, cwd: cwd, sessionId: "saved-thread",
                           model: model, permissionMode: mode, clientSessionKey: "saved-thread", history: history)
    }

    private func events(_ backend: FlowcyCloudBackend, _ turn: BackendSendRequest) async -> [StreamEvent] {
        var events: [StreamEvent] = []
        for await event in await backend.send(turn) { events.append(event) }
        return events
    }

    func testCatalogUsesProductionAndRefreshesExpiredToken() async throws {
        let models = try await backend(token: "catalog").fetchModels()
        XCTAssertEqual(models, [AgentModel(provider: .flowcy, id: "model-a", displayName: "Model A")])
    }

    func testDefaultModelReplaysSavedTextAndStreamsDeltas() async throws {
        let backend = backend(token: "history")
        let turn = request(model: AgentModel.flowcyDefaultID, history: [
            ChatMessage(role: .user, content: "First question"), ChatMessage(role: .assistant, content: "First answer"),
            ChatMessage(role: .assistant, content: "Local error", isError: true)
        ])
        var chunks: [String] = []
        var result: ResultEvent?
        for await event in await backend.send(turn) {
            switch event {
            case .textDelta(let delta): chunks.append(delta)
            case .result(let value): result = value
            default: break
            }
        }
        XCTAssertEqual(chunks, ["Hello ", "again"])
        XCTAssertEqual(result?.sessionId, "saved-thread")
        XCTAssertEqual(result?.isError, false)
    }

    func testInterruptedExplicitModelReplyReportsErrorAfterFinalizing() async throws {
        let backend = backend(token: "interrupted")
        let turn = request(model: "model-a")
        var failed = false
        for await event in await backend.send(turn) {
            if case .result(let result) = event { failed = result.isError }
        }
        await backend.finalize(streamId: turn.streamId)
        let detail = await backend.consumeStderr(for: turn.streamId)
        XCTAssertTrue(failed)
        XCTAssertEqual(detail, "Flowcy response was interrupted.")
    }

    func testTerminalReturnsBranchFromSelectedWorktree() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: [String]) throws {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false"] + arguments
            git.currentDirectoryURL = root
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        let branch = "topic-\(UUID().uuidString)"
        try git(["init", "-q", "-b", "main", "repo"])
        try git(["-C", "repo", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.test",
                 "commit", "-q", "--allow-empty", "-m", "Initial"])
        try git(["-C", "repo", "worktree", "add", "-q", "-b", branch, "../linked"])

        let app = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        let project = Project(name: "Worktree fixture", path: root.appending(path: "repo").path)
        app.projects = [project]
        let window = WindowState()
        window.selectedProject = project
        window.sessionAgentProvider = .flowcy
        window.sessionModel = AgentModel.flowcyDefaultID
        window.sessionPermissionMode = .auto
        window.pendingWorktreePath = root.appending(path: "linked").path
        window.pendingWorktreeBranch = branch
        let service: FlowcyCloudBackend
        if let address = ProcessInfo.processInfo.environment["FLOWCY_SIMULATION_BASE_URL"] {
            service = FlowcyCloudBackend(baseURL: try XCTUnwrap(URL(string: address)), permission: app.permission) { _ in "simulation" }
        } else {
            service = backend(token: "terminal", permission: app.permission)
        }
        app.agentBackendOverrides[.flowcy] = service
        let sent = await app.sendPrompt("Which branch is checked out?", in: window)
        let streamID = try XCTUnwrap(sent)
        let completion = await app.awaitStreamCompletion(streamId: streamID, timeout: 20, acceptsPartial: false)
        guard let completion else {
            await app.cancelStreaming(in: window, fireStopHooks: false)
            return XCTFail("The project chat did not finish")
        }
        XCTAssertNil(completion.error)
        let messages = app.messages(in: window)
        let command = try XCTUnwrap(messages.flatMap(\.toolCalls).first { $0.name == "Bash" })
        XCTAssertEqual(command.input["command"], .string("git branch --show-current"))
        XCTAssertEqual(command.result?.trimmingCharacters(in: .whitespacesAndNewlines), branch)
        XCTAssertFalse(command.isError)
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == branch })
    }

    func testDenialAndCancellationAtNativeCommandApproval() async throws {
        let cwd = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        for cancel in [false, true] {
            let permission = PermissionServer()
            let subscription = await permission.subscribe()
            let service = backend(token: "permission", permission: permission)
            let turn = request(cwd: cwd.path)
            let completion = Task { await self.events(service, turn) }
            let prompted = expectation(description: "The native permission queue receives the command")
            let responder = Task {
                for await approval in subscription.stream {
                    XCTAssertEqual(approval.sessionId, turn.clientSessionKey)
                    XCTAssertEqual(approval.toolInput["command"], .string("touch marker"))
                    if cancel { await service.cancel(streamId: turn.streamId) }
                    else { await permission.respond(toolUseId: approval.id, decision: .deny) }
                    prompted.fulfill()
                    break
                }
            }
            await fulfillment(of: [prompted], timeout: 10)
            await permission.unsubscribe(token: subscription.token)
            await responder.value
            let messages = await completion.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appending(path: "marker").path))
            if cancel {
                XCTAssertFalse(messages.contains { if case .result = $0 { true } else { false } })
            } else {
                XCTAssertTrue(messages.contains { if case .user(let result) = $0 { result.isError } else { false } })
                guard case .result(let result) = messages.last else { return XCTFail("Missing turn result after denial") }
                XCTAssertFalse(result.isError)
            }
        }
    }

    func testInvalidOrIncompleteToolBatchAndPlanModeCannotExecute() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for scenario in ["duplicate", "incomplete", "unknown", "plan"] {
            let service = backend(token: scenario)
            let turn = request(cwd: root.path, mode: scenario == "plan" ? .plan : .bypassPermissions)
            let messages = await events(service, turn)
            guard case .result(let result) = messages.last else { return XCTFail("Missing result for \(scenario)") }
            XCTAssertTrue(result.isError, scenario)
            XCTAssertFalse(messages.contains { if case .user = $0 { true } else { false } }, scenario)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "marker").path), scenario)
        }
    }

    func testOneShotCloudChatRejectsLocalTools() async throws {
        do {
            _ = try await backend(token: "one-shot").reply(model: nil, prompt: "Continue")
            XCTFail("Unexpected terminal call in a text reply")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Flowcy requested an unavailable or invalid tool.")
        }
    }

    func testSavedTerminalResultIsReplayedWithoutRunningItAgain() async throws {
        let call = ToolCall(id: "flowcy:\(UUID().uuidString):saved-call", name: "Bash",
                            input: ["command": .string("git status")], result: "On branch topic")
        let hook = ToolCall(id: "hook", name: "Hook: Lint", input: [:], result: "Local hook output")
        let history = [ChatMessage(role: .user, content: "Inspect the branch"),
                       ChatMessage(role: .assistant, blocks: [.toolCall(call), .toolCall(hook), .text("Done")])]
        let messages = await events(backend(token: "replay"), request(history: history))
        guard case .result(let result) = messages.last else { return XCTFail("Missing result") }
        XCTAssertFalse(result.isError)
    }
}

nonisolated private final class FlowcyChatFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return XCTFail("Missing URL") }
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.flowcy.dev")
        let bearer = request.value(forHTTPHeaderField: "Authorization")
        if bearer == "Bearer expired" {
            respond(url, status: 401, contentType: "application/json", body: "{}")
        } else if bearer == "Bearer catalog" {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(url.path, "/api/v1/agent/models")
            respond(url, contentType: "application/json", body: #"{"models":[{"modelId":"model-a","alias":"Model A"}]}"#)
        } else {
            XCTAssertEqual(url.path, "/api/v1/agent/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/x-ndjson")
            do {
                let input = try bodyJSON()
                let tools = try XCTUnwrap(input["tools"]?.arrayValue)
                let messages = try XCTUnwrap(input["messages"]?.arrayValue)
                let toolFree = ["Bearer one-shot", "Bearer plan"].contains(bearer)
                XCTAssertEqual(tools.compactMap { $0["name"]?.stringValue }, toolFree ? [] : ["bash"])
                if bearer == "Bearer history" {
                    XCTAssertNil(input["modelId"])
                    XCTAssertEqual(messages.compactMap { $0["content"]?.stringValue }, ["First question", "First answer", "Continue"])
                    XCTAssertEqual(messages.compactMap { $0["role"]?.stringValue }, ["user", "assistant", "user"])
                    respond(url, contentType: "application/x-ndjson", body: """
                        {"type":"text","text":"Hello "}
                        {"type":"text","text":"again"}
                        {"type":"finish"}
                        """)
                } else if bearer == "Bearer interrupted" {
                    XCTAssertEqual(input["modelId"], .string("model-a"))
                    respond(url, contentType: "application/x-ndjson", body: #"{"type":"text","text":"Partial"}"#)
                } else if bearer == "Bearer replay" {
                    XCTAssertEqual(messages.compactMap { $0["role"]?.stringValue }, ["user", "assistant", "tool", "assistant", "user"])
                    guard messages.count == 5 else { throw IDEToolError.invalidArguments("Unexpected replay length.") }
                    let call = try XCTUnwrap(messages[1]["content"]?.arrayValue?.first)
                    let result = try XCTUnwrap(messages[2]["content"]?.arrayValue?.first)
                    XCTAssertEqual(call["toolCallId"], .string("saved-call"))
                    XCTAssertEqual(call["toolName"], .string("bash"))
                    XCTAssertEqual(result["toolCallId"], call["toolCallId"])
                    XCTAssertEqual(result["output"]?["value"], .string("On branch topic"))
                    XCTAssertEqual(messages[3]["content"], .string("Done"))
                    respond(url, contentType: "application/x-ndjson", body: #"{"type":"finish"}"#)
                } else if messages.last?["role"] == .string("tool") {
                    let call = try XCTUnwrap(messages.dropLast().last?["content"]?.arrayValue?.last)
                    let result = try XCTUnwrap(messages.last?["content"]?.arrayValue?.first)
                    XCTAssertEqual(call["type"], .string("tool-call"))
                    XCTAssertEqual(call["toolName"], .string("bash"))
                    XCTAssertEqual(result["type"], .string("tool-result"))
                    XCTAssertEqual(result["toolName"], call["toolName"])
                    XCTAssertEqual(result["toolCallId"], call["toolCallId"])
                    XCTAssertEqual(result["output"]?["type"], .string(bearer == "Bearer permission" ? "error-text" : "text"))
                    let output = try XCTUnwrap(result["output"]?["value"]?.stringValue)
                    if bearer == "Bearer permission" { XCTAssertEqual(output, "The user denied this command.") }
                    let delta: JSONValue = .object(["type": .string("text"), "text": .string(output.trimmingCharacters(in: .whitespacesAndNewlines))])
                    let line = String(decoding: try JSONEncoder().encode(delta), as: UTF8.self)
                    respond(url, contentType: "application/x-ndjson", body: line + "\n" + #"{"type":"finish"}"#)
                } else {
                    let command = bearer == "Bearer terminal" ? "git branch --show-current" : "touch marker"
                    let call = #"{"type":"tool-call","id":"call","name":"bash","arguments":{"command":"\#(command)"}}"#
                    var lines = [call]
                    if bearer == "Bearer duplicate" { lines.append(call) }
                    if bearer == "Bearer unknown" { lines.append(#"{"type":"tool-call","id":"other","name":"undeclared","arguments":{}}"#) }
                    if bearer != "Bearer incomplete" { lines.append(#"{"type":"finish"}"#) }
                    respond(url, contentType: "application/x-ndjson", body: lines.joined(separator: "\n"))
                }
            } catch {
                XCTFail("Invalid request body.")
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    private func bodyJSON() throws -> JSONValue {
        if let data = request.httpBody { return try JSONDecoder().decode(JSONValue.self, from: data) }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        let object = try JSONSerialization.jsonObject(with: stream)
        return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func respond(_ url: URL, status: Int = 200, contentType: String, body: String) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
