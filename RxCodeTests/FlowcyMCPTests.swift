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
    private func backend(token: String) -> FlowcyCloudBackend {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlowcyChatFixture.self]
        return FlowcyCloudBackend(baseURL: FlowcyCloudBackend.productionURL, session: URLSession(configuration: config)) {
            $0 ? token : "expired"
        }
    }

    private func request(model: String?, history: [ChatMessage] = []) -> BackendSendRequest {
        BackendSendRequest(streamId: UUID(), prompt: "Continue", cwd: "/project", sessionId: "saved-thread",
                           model: model, permissionMode: .default, clientSessionKey: "saved-thread", history: history)
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
                XCTAssertEqual(input["tools"], .array([]))
                if bearer == "Bearer history" {
                    XCTAssertNil(input["modelId"])
                    let messages = try XCTUnwrap(input["messages"]?.arrayValue)
                    XCTAssertEqual(messages.compactMap { $0["content"]?.stringValue }, ["First question", "First answer", "Continue"])
                    XCTAssertEqual(messages.compactMap { $0["role"]?.stringValue }, ["user", "assistant", "user"])
                    respond(url, contentType: "application/x-ndjson", body: """
                        {"type":"text","text":"Hello "}
                        {"type":"text","text":"again"}
                        {"type":"finish"}
                        """)
                } else {
                    XCTAssertEqual(bearer, "Bearer interrupted")
                    XCTAssertEqual(input["modelId"], .string("model-a"))
                    respond(url, contentType: "application/x-ndjson", body: #"{"type":"text","text":"Partial"}"#)
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
