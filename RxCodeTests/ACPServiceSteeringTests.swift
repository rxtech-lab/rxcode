import Foundation
import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class ACPServiceSteeringTests: XCTestCase {
    func testInterruptWaitsForTheOriginalPromptBeforeContinuingTheSameSession() async throws {
        let (service, spec, directory) = try fixture(mode: "permission")
        let sessionID = directory.lastPathComponent
        let permissions = PermissionServer()
        await service.setPermissionServer(permissions)
        let subscription = await permissions.subscribe()
        let permissionRequested = expectation(description: "Agent has an unanswered permission request")
        let permissionConsumer = Task {
            for await _ in subscription.stream {
                permissionRequested.fulfill()
                break
            }
        }
        defer { permissionConsumer.cancel() }
        let first = UUID()
        let firstStream = await service.send(
            streamId: first, prompt: "original instruction", cwd: directory.path, sessionId: nil,
            model: nil, spec: spec, permissionMode: .default, clientSessionKey: "local-thread"
        )
        let active = expectation(description: "Original prompt is streaming")
        let original = Task { () -> [String] in
            var chunks: [String] = []
            for await event in firstStream {
                if case .unknown(let frame) = event {
                    chunks.append(frame)
                    if frame.contains("before cancellation") { active.fulfill() }
                }
            }
            return chunks
        }
        await fulfillment(of: [active, permissionRequested], timeout: 5)

        await service.cancel(streamId: first)
        await service.finalize(streamId: first)
        let followUp = await service.send(
            streamId: UUID(), prompt: "redirect", cwd: directory.path, sessionId: sessionID,
            model: nil, spec: spec, permissionMode: .default, clientSessionKey: sessionID
        )
        var output: [String] = []
        var result: ResultEvent?
        for await event in followUp {
            if case .unknown(let frame) = event { output.append(frame) }
            if case .result(let value) = event { result = value }
        }
        let originalOutput = await original.value
        XCTAssertTrue(originalOutput.last?.contains("after cancellation") == true)
        XCTAssertEqual(result?.isError, false)
        XCTAssertEqual(result?.sessionId, sessionID)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output.first?.contains("remembered original instruction, then redirect") == true)
    }

    func testSteerPreservesWireOrderEvenWhenOutputPrecedesItsReceipt() async throws {
        let (service, spec, cwd) = try fixture(mode: "steer")
        let (streamId, consumer) = await beginTurn(service, spec: spec, cwd: cwd)
        let message = ChatMessage(role: .user, content: "redirect")
        let receipt = await service.steer(streamId: streamId, prompt: message.content, message: message)
        XCTAssertEqual(receipt, .injected)
        let events = await consumer.value
        XCTAssertEqual(eventNames(events), ["steer available", "before cancellation", "user: redirect", "after steer", "result"])
    }

    func testSteerDeclinedAfterOriginalResultLeavesInputForNormalPrompt() async throws {
        let (service, spec, cwd) = try fixture(mode: "idle-race")
        let sessionID = cwd.lastPathComponent
        let (streamId, consumer) = await beginTurn(service, spec: spec, cwd: cwd)
        let message = ChatMessage(role: .user, content: "redirect")
        let receipt = await service.steer(streamId: streamId, prompt: message.content, message: message)
        XCTAssertEqual(receipt, .declined)
        let events = await consumer.value
        XCTAssertEqual(eventNames(events), ["steer available", "before cancellation", "result"])
        let next = await service.send(
            streamId: UUID(), prompt: message.content, cwd: cwd.path, sessionId: sessionID,
            model: nil, spec: spec, permissionMode: .default, clientSessionKey: sessionID
        )
        var names: [String] = []
        for await event in next { names += eventNames([event]) }
        XCTAssertEqual(names, ["steer available", "remembered original instruction, then redirect", "result"])
    }

    func testLegacyOrUnadvertisedSteerDeclinesWithoutSendingAnRPC() async throws {
        for mode in ["unsupported", "legacy"] {
            let (service, spec, cwd) = try fixture(mode: mode)
            let (streamId, consumer) = await beginTurn(service, spec: spec, cwd: cwd)
            let message = ChatMessage(role: .user, content: "redirect")
            let receipt = await service.steer(streamId: streamId, prompt: message.content, message: message)
            XCTAssertEqual(receipt, .declined)
            let pid = await service.rootPid(for: streamId)
            XCTAssertNotNil(pid)
            await service.cancel(streamId: streamId)
            let events = await consumer.value
            XCTAssertEqual(eventNames(events), ["steer unavailable", "before cancellation", "after cancellation", "result"])
        }
    }

    func testMissingSteerReceiptKeepsInstructionVisibleWithoutReplayingIt() async throws {
        let (service, spec, cwd) = try fixture(mode: "no-receipt")
        let (appState, window, streamId) = try await beginChat(service, spec: spec, cwd: cwd)
        appState.enqueueMessage(text: "redirect", attachments: [], in: window)
        let queued = try XCTUnwrap(window.messageQueue.first)
        _ = await appState.steerQueuedMessage(id: queued.id, in: window)
        _ = await appState.awaitStreamCompletion(streamId: streamId, timeout: 5, acceptsPartial: false)
        let messages = appState.stateForSession(cwd.lastPathComponent).messages
        XCTAssertEqual(messages.filter { $0.role == .user }.map(\.content), ["original instruction", "redirect"])
        XCTAssertTrue(messages.last?.isError == true)
        XCTAssertTrue(window.messageQueue.isEmpty)
    }

    func testAppContinuesOnTheSameACPStreamAndRecordsTheSteerOnce() async throws {
        let (service, spec, cwd) = try fixture(mode: "steer")
        let sessionID = cwd.lastPathComponent
        let (appState, window, streamId) = try await beginChat(service, spec: spec, cwd: cwd)
        XCTAssertTrue(appState.canSteer(in: window))
        appState.enqueueMessage(text: "redirect", attachments: [], in: window)
        let queued = try XCTUnwrap(window.messageQueue.first)
        let accepted = await appState.steerQueuedMessage(id: queued.id, in: window)
        XCTAssertTrue(accepted)
        let result = await appState.awaitStreamCompletion(streamId: streamId, timeout: 5, acceptsPartial: false)
        XCTAssertEqual(result?.sessionId, sessionID)
        XCTAssertEqual(appState.stateForSession(sessionID).messages.map(\.content),
                       ["original instruction", "before cancellation", "redirect", "after steer"])
        XCTAssertTrue(window.messageQueue.isEmpty)
        XCTAssertTrue(appState.threadStore.loadQueue(sessionKey: sessionID).isEmpty)
    }

    func testAppInterruptsAnUnsupportedClientAndSendsInTheSameThread() async throws {
        let (service, spec, cwd) = try fixture(mode: "unsupported")
        let sessionID = cwd.lastPathComponent
        let (appState, window, _) = try await beginChat(service, spec: spec, cwd: cwd)
        XCTAssertFalse(appState.canSteer(in: window))
        appState.enqueueMessage(text: "redirect", attachments: [], in: window)
        let queued = try XCTUnwrap(window.messageQueue.first)
        await appState.sendQueuedNow(id: queued.id, in: window)
        try await waitUntil {
            !appState.stateForSession(sessionID).isStreaming
        }
        let messages = appState.stateForSession(sessionID).messages
        XCTAssertEqual(messages.filter { $0.role == .user }.map(\.content), ["original instruction", "redirect"])
        XCTAssertTrue(messages.contains { $0.role == .assistant && $0.content == "remembered original instruction, then redirect" })
        XCTAssertEqual(window.currentSessionId, sessionID)
        XCTAssertTrue(window.messageQueue.isEmpty)
    }

    func testDisconnectedClientLeavesInterruptInstructionQueued() async throws {
        let (service, spec, cwd) = try fixture(mode: "disconnect")
        let (appState, window, _) = try await beginChat(service, spec: spec, cwd: cwd)
        appState.enqueueMessage(text: "redirect", attachments: [], in: window)
        let queued = try XCTUnwrap(window.messageQueue.first)
        await appState.sendQueuedNow(id: queued.id, in: window)
        await appState.sendQueuedNow(id: queued.id, in: window)
        XCTAssertTrue(window.showError)
        XCTAssertEqual(window.messageQueue.map(\.id), [queued.id])
        XCTAssertEqual(appState.threadStore.loadQueue(sessionKey: cwd.lastPathComponent).map(\.id), [queued.id])
        XCTAssertEqual(appState.stateForSession(cwd.lastPathComponent).messages.filter { $0.role == .user }.map(\.content),
                       ["original instruction"])
    }

    func testAppFlushesDeclinedSteerAndLaterMessageOnceInQueueOrder() async throws {
        let (service, spec, cwd) = try fixture(mode: "idle-race")
        let sessionID = cwd.lastPathComponent
        let (appState, window, _) = try await beginChat(service, spec: spec, cwd: cwd)
        appState.enqueueMessage(text: "redirect", attachments: [], in: window)
        let queued = try XCTUnwrap(window.messageQueue.first)
        let attempt = Task { await appState.steerQueuedMessage(id: queued.id, in: window) }
        try await waitUntil { appState.stateForSession(sessionID).queueDispatchInProgress }
        appState.enqueueMessage(text: "later instruction", attachments: [], in: window)
        let result = await attempt.value
        XCTAssertFalse(result)
        try await waitUntil {
            let state = appState.stateForSession(sessionID)
            return !state.isStreaming && state.messages.contains {
                $0.role == .assistant && $0.content == "remembered original instruction, then later instruction"
            }
        }
        let messages = appState.stateForSession(sessionID).messages
        XCTAssertEqual(messages.filter { $0.role == .user }.map(\.content),
                       ["original instruction", "redirect", "later instruction"])
        XCTAssertEqual(messages.filter { $0.role == .assistant && $0.content == "remembered original instruction, then redirect" }.count, 1)
        XCTAssertTrue(appState.threadStore.loadQueue(sessionKey: sessionID).isEmpty)
    }

    private func beginTurn(_ service: ACPService, spec: ACPClientSpec, cwd: URL) async -> (UUID, Task<[StreamEvent], Never>) {
        let id = UUID()
        let stream = await service.send(
            streamId: id, prompt: "original instruction", cwd: cwd.path, sessionId: nil,
            model: nil, spec: spec, permissionMode: .default, clientSessionKey: "local-thread"
        )
        let active = expectation(description: "Original prompt is streaming")
        let consumer = Task { () -> [StreamEvent] in
            var events: [StreamEvent] = []
            for await event in stream {
                events.append(event)
                if case .unknown(let frame) = event, frame.contains("before cancellation") { active.fulfill() }
            }
            return events
        }
        await fulfillment(of: [active], timeout: 5)
        return (id, consumer)
    }

    private func eventNames(_ events: [StreamEvent]) -> [String] {
        events.compactMap { event in
            switch event {
            case .acpSteeringAvailable(let available): available ? "steer available" : "steer unavailable"
            case .acpSteeredMessage(let message, let confirmed): confirmed ? "user: \(message.content)" : "unconfirmed"
            case .unknown(let frame):
                (try? JSONDecoder().decode(JSONValue.self, from: Data(frame.utf8)))?["delta"]?["text"]?.stringValue
            case .result: "result"
            default: nil
            }
        }
    }

    private func beginChat(_ service: ACPService, spec: ACPClientSpec, cwd: URL) async throws -> (AppState, WindowState, UUID) {
        let appState = AppState(persistence: MockAppStatePersistence(), startBackgroundServices: false)
        appState.agentBackendOverrides[.acp] = service
        appState.acpClients = [spec]
        let project = Project(name: "ACP steering", path: cwd.path, gitHubRepo: nil)
        appState.projects = [project]
        let window = WindowState()
        window.selectedProject = project
        window.sessionAgentProvider = .acp
        window.sessionModel = "\(spec.id)::default"
        let streamId = await appState.sendPrompt("original instruction", includeIDEMCP: false, in: window)
        try await waitUntil {
            appState.stateForSession(cwd.lastPathComponent).textDeltaBuffer == "before cancellation"
        }
        return (appState, window, try XCTUnwrap(streamId))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<180 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("ACP fixture did not reach the expected state")
        throw ACPError.streamClosed
    }

    private func fixture(mode: String) throws -> (ACPService, ACPClientSpec, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acp-steer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = ACPService()
        addTeardownBlock {
            await service.cleanup()
            try? FileManager.default.removeItem(at: directory)
        }
        let script = directory.appendingPathComponent("agent.py")
        try #"""
        import json, os, sys, threading, time

        mode = sys.argv[1]
        sid = os.path.basename(os.getcwd())
        initial = None
        current = None
        cancelling = False
        deadline = threading.Timer(15, lambda: os._exit(1))
        deadline.daemon = True
        deadline.start()

        def emit(**value):
            print(json.dumps(dict(jsonrpc="2.0", **value)), flush=True)

        def reply(id, **result):
            emit(id=id, result=result)

        def chunk(text, kind="agent_message_chunk"):
            emit(method="session/update", params={"sessionId": sid, "update": {
                "sessionUpdate": kind, "content": {"type": "text", "text": text}
            }})

        def finish_cancel():
            global current
            chunk("after cancellation")
            id, current = current, None
            reply(id, stopReason="cancelled")

        for line in sys.stdin:
            request = json.loads(line)
            method, id = request.get("method"), request.get("id")
            if method == "initialize":
                init = dict(protocolVersion=1, agentCapabilities={})
                if mode in ("steer", "idle-race", "no-receipt", "legacy"):
                    init["_meta"] = {"steering": {"supported": True}}
                    init["agentInfo"] = {"name": "@agentclientprotocol/codex-acp",
                                         "version": "2.3.0" if mode == "legacy" else "2.4.0"}
                reply(id, **init)
            elif method == "session/new":
                assert initial is None, "Expected same ACP session"
                reply(id, sessionId=sid)
            elif method == "session/cancel":
                assert request["params"]["sessionId"] == sid
                assert not cancelling, "Repeated cancellation"
                cancelling = True
                if mode == "disconnect":
                    sys.exit(0)
                if current is not None and mode != "permission":
                    threading.Timer(0.3, finish_cancel).start()
            elif id == "pending-permission":
                assert cancelling and request["result"]["outcome"]["outcome"] == "cancelled"
                threading.Timer(0.3, finish_cancel).start()
            elif method == "_session/steering":
                assert mode in ("steer", "idle-race", "no-receipt") and current is not None
                assert request["params"]["sessionId"] == sid
                assert request["params"]["_meta"]["steering"]["idleBehavior"] == "promptRequired"
                assert request["params"]["prompt"][0]["text"] == "redirect"
                if mode == "idle-race":
                    reply(current, stopReason="end_turn")
                    current = None
                    time.sleep(0.2)
                    reply(id, outcome="promptRequired", reason="noRunningTurn")
                elif mode == "steer":
                    chunk("redirect", kind="user_message_chunk")
                    chunk("after steer")
                    time.sleep(0.1)
                    reply(id, outcome="injected")
                    reply(current, stopReason="end_turn")
                    current = None
                else:
                    reply(current, stopReason="end_turn")
                    current = None
            elif method == "session/prompt":
                assert request["params"]["sessionId"] == sid
                text = request["params"]["prompt"][0]["text"].rsplit("\nUser request:\n", 1)[-1].strip()
                if current is not None:
                    emit(id=id, error={"code": -32600, "message": "Previous prompt is still active"})
                elif initial is None:
                    initial, current = text, id
                    chunk("before cancellation")
                    if mode == "permission":
                        emit(id="pending-permission", method="session/request_permission", params={
                            "sessionId": sid, "toolCall": {"toolCallId": "tool-id", "title": "Bash"},
                            "options": [{"optionId": "allow", "kind": "allow_once", "name": "Allow"}]
                        })
                else:
                    chunk("remembered " + initial + ", then " + text)
                    reply(id, stopReason="end_turn")
        """#.write(to: script, atomically: true, encoding: .utf8)
        return (service, ACPClientSpec(
            displayName: "ACP fixture", launch: .binary(path: "/usr/bin/python3", args: ["-u", script.path, mode], env: [:])
        ), directory)
    }
}
