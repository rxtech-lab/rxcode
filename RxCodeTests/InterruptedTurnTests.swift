import RxCodeCore
import XCTest
@testable import RxCode

@MainActor
final class InterruptedTurnTests: XCTestCase {
    private let workspace = AppWorkspace(id: UUID().uuidString, name: "Recovery", createdAt: .now, updatedAt: .now)
    private let project = Project(name: "Recovery", path: NSTemporaryDirectory())

    private func openWorkspace() async -> AppState {
        let app = AppState(core: AppCore(), workspace: workspace, startBackgroundServices: false)
        app.projects = [project]
        app.allSessionSummaries = await app.threadStoreReader.loadSummaries()
        return app
    }

    private func window(for session: ChatSession, app: AppState) -> WindowState {
        let window = WindowState()
        window.selectedProject = project
        app.switchToSession(session, messages: session.messages, in: window)
        return window
    }

    private func seed(_ session: ChatSession, in app: AppState) {
        app.threadStore.upsert(session.summary)
        app.allSessionSummaries = [session.summary]
    }

    func testErrorRetainsIntermediateMessagesAndResumeContinuesTheSameThreadOnce() async throws {
        let id = UUID().uuidString
        let app = await openWorkspace()
        let initial = ChatSession(id: id, projectId: project.id, title: "Recovery test",
                                  messages: [ChatMessage(role: .user, content: "Prior question"),
                                             ChatMessage(role: .assistant, content: "Prior answer", isResponseComplete: true)],
                                  agentProvider: .claudeCode, model: "test", origin: .cliBacked)
        seed(initial, in: app)
        let firstWindow = window(for: initial, app: app)
        let backend = MockAgentBackend(provider: .claudeCode)
        app.agentBackendOverrides[.claudeCode] = backend
        await backend.enqueueScript([
            .systemInit(sessionId: id),
            .init(delay: 0, event: .textDelta("Checking the first file.")),
            .init(delay: 0, event: .toolCallStarted(id: "read", name: "Read")),
            .init(delay: 0, event: .user(.init(toolUseId: "read", content: "file contents", isError: false))),
            .init(delay: 0, event: .textDelta("Checking the second file.")),
            .init(delay: 0, event: .toolCallStarted(id: "search", name: "Grep")),
            .init(delay: 0, event: .user(.init(toolUseId: nil, content: "Connection closed", isError: true))),
            .result(sessionId: id, isError: true)
        ], forCwd: project.path)
        _ = await app.sendPrompt("Check both files", includeIDEMCP: false, in: firstWindow)
        let failedTurn = try XCTUnwrap(app.sessionStates[id]?.streamTask)
        await failedTurn.value

        let reopened = await openWorkspace()
        let summary = try XCTUnwrap(reopened.allSessionSummaries.first)
        XCTAssertEqual(summary.hasUnfinishedTurn, true)
        XCTAssertEqual(reopened.mobileSessionSummary(for: id)?.isInterrupted, true)
        let disk = await reopened.persistence.loadFullSession(summary: summary, cwd: project.path)
        let saved = try XCTUnwrap(disk)
        XCTAssertEqual(saved.messages.map(\.content), [
            "Prior question", "Prior answer", "Check both files", "Checking the first file.",
            "Checking the second file.", "Connection closed"
        ])
        XCTAssertEqual(saved.messages.flatMap(\.toolCalls).map(\.result), ["file contents", "Interrupted"])
        XCTAssertTrue(saved.messages.last?.isError == true)
        XCTAssertFalse(saved.messages.contains(where: \.isStreaming))

        let restoredWindow = window(for: saved, app: reopened)
        restoredWindow.inputText = "Unsent draft"
        reopened.agentBackendOverrides[.claudeCode] = backend
        await backend.enqueueScript([
            .systemInit(sessionId: id), .init(delay: 0, event: .textDelta("Finished checking.")), .result(sessionId: id)
        ], forCwd: project.path)
        let resumed = await reopened.resumeInterruptedTurn(in: restoredWindow)
        XCTAssertNotNil(resumed)
        let resumedTurn = try XCTUnwrap(reopened.sessionStates[id]?.streamTask)
        let duplicate = await reopened.resumeInterruptedTurn(in: restoredWindow)
        XCTAssertNil(duplicate)
        await resumedTurn.value
        let requests = await backend.receivedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.sessionId, id)
        XCTAssertEqual(restoredWindow.inputText, "Unsent draft")
        let completed = try XCTUnwrap(reopened.threadStore.fetch(id: id)?.toSummary())
        XCTAssertEqual(completed.hasUnfinishedTurn, false)
        let final = await reopened.persistence.loadFullSession(summary: completed, cwd: project.path)
        XCTAssertEqual(final?.messages.dropLast().map(\.id), saved.messages.map(\.id))
        XCTAssertEqual(final?.messages.last?.content, "Finished checking.")
    }

    func testExitFlushesBufferedTextAndPreservesAPreInitThreadOnResume() async throws {
        let app = await openWorkspace()
        let stream = UUID()
        let id = "pending-\(stream.uuidString)"
        let initial = ChatSession(id: id, projectId: project.id, title: "Pending request",
                                  messages: [ChatMessage(role: .user, content: "Inspect the build")],
                                  agentProvider: .codex, model: "test", origin: .codexAppServer)
        seed(initial, in: app)
        let first = window(for: initial, app: app)
        app.updateState(id) { $0.isStreaming = true; $0.activeStreamId = stream }
        await app.beginTurnRecovery(sessionID: id, streamID: stream)
        app.applyTextDelta("Inspecting the build.", for: id)
        app.beginToolCall(id: "tool", name: "Read", for: id)
        app.updateState(id) { state in
            state.pendingToolResults = [("tool", "package contents", false)]
            state.needsNewMessage = true
        }
        app.applyTextDelta("Buffered tail", for: id)
        app.startNewChat(in: first)
        app.applyTextDelta(" after switching threads", for: id)
        await app.checkpointActiveTurns()

        let reopened = await openWorkspace()
        let summary = try XCTUnwrap(reopened.allSessionSummaries.first)
        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.hasUnfinishedTurn, true)
        let disk = await reopened.persistence.loadFullSession(summary: summary, cwd: project.path)
        let saved = try XCTUnwrap(disk)
        XCTAssertEqual(saved.messages.map(\.content), ["Inspect the build", "Inspecting the build.", "Buffered tail after switching threads"])
        XCTAssertEqual(saved.messages.flatMap(\.toolCalls).first?.result, "package contents")
        let restored = window(for: saved, app: reopened)
        let nativeID = UUID().uuidString
        let backend = MockAgentBackend(provider: .codex)
        reopened.agentBackendOverrides[.codex] = backend
        await backend.enqueueScript([.systemInit(sessionId: nativeID), .assistantText("Done"), .result(sessionId: nativeID)], forCwd: project.path)
        _ = await reopened.resumeInterruptedTurn(in: restored)
        let task = try XCTUnwrap(reopened.streamState(in: restored).streamTask)
        await task.value
        let requests = await backend.receivedRequests
        XCTAssertNil(requests.first?.sessionId)
        XCTAssertTrue(requests.first?.prompt.contains("Inspect the build") == true)
        XCTAssertTrue(requests.first?.prompt.contains("Buffered tail after switching threads") == true)
        XCTAssertEqual(restored.currentSessionId, nativeID)
        XCTAssertEqual(reopened.threadStore.loadAllSummaries().map(\.id), [nativeID])
        XCTAssertEqual(reopened.threadStore.fetch(id: nativeID)?.hasUnfinishedTurn, false)
        XCTAssertEqual(reopened.streamState(in: restored).messages.filter { $0.role == .user }.count, 1)
    }

    func testUnexpectedEOFIsInterruptedAndDeliberateStopIsSettled() async throws {
        let app = await openWorkspace()
        let id = UUID().uuidString
        let initial = ChatSession(id: id, projectId: project.id, title: "Stop test",
                                  messages: [ChatMessage(role: .user, content: "Previous request")],
                                  agentProvider: .flowcy, model: "test", origin: .legacyRxCode)
        seed(initial, in: app)
        let window = window(for: initial, app: app)
        let backend = MockAgentBackend(provider: .flowcy)
        app.agentBackendOverrides[.flowcy] = backend
        await backend.enqueueScript([.systemInit(sessionId: id), .init(delay: 0, event: .textDelta("Partial reply"))], forCwd: project.path)
        _ = await app.sendPrompt("Continue", includeIDEMCP: false, in: window)
        let task = try XCTUnwrap(app.sessionStates[id]?.streamTask)
        await task.value
        XCTAssertEqual(app.threadStore.fetch(id: id)?.hasUnfinishedTurn, true)
        XCTAssertTrue(app.messages(in: window).contains(where: { $0.content == "Partial reply" }))

        let stream = UUID()
        app.updateState(id) { state in
            state.isStreaming = true
            state.activeStreamId = stream
            state.messages.append(ChatMessage(role: .user, content: "New request"))
        }
        await app.beginTurnRecovery(sessionID: id, streamID: stream)
        app.applyTextDelta("Stopping here", for: id)
        await app.cancelStreaming(in: window, fireStopHooks: false)
        XCTAssertEqual(app.threadStore.fetch(id: id)?.hasUnfinishedTurn, false)
        let resume = await app.resumeInterruptedTurn(in: window)
        XCTAssertNil(resume)
        XCTAssertEqual(app.messages(in: window).last?.content, "Stopping here")
    }
}
