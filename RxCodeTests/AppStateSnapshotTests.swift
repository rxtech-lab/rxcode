import Observation
import os
import XCTest
import RxCodeCore
import RxCodeSync
@testable import RxCode

@MainActor
final class AppStateSnapshotTests: XCTestCase {
    private var persistence: MockAppStatePersistence!
    private var appState: AppState!
    private var window: WindowState!

    override func setUp() async throws {
        persistence = MockAppStatePersistence()
        appState = AppState(persistence: persistence, startBackgroundServices: false)
        window = WindowState()
    }

    override func tearDown() async throws {
        window = nil
        appState = nil
        persistence = nil
    }

    func testPreviewObservesWindowChangesIndependentlyOfStreamTraffic() {
        let session = "preview"
        appState.sessionStates[session] = streamState(isStreaming: true)
        let firstWindow = ComputerUseMonitorWindow(id: .native(appID: "test"), title: "First")
        let appeared = expectation(description: "Window appeared")
        withObservationTracking {
            XCTAssertTrue(appState.computerUseMonitors(forSession: session).isEmpty)
        } onChange: {
            appeared.fulfill()
        }
        appState.sessionStates[session]?.computerUseWindows = [firstWindow]
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 0), .completed)

        let invalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            XCTAssertEqual(appState.computerUseMonitors(forSession: session), [firstWindow])
        } onChange: {
            invalidations.withLock { $0 += 1 }
        }
        for index in 0..<500 {
            appState.sessionStates[session]?.textDeltaBuffer = String(index)
        }
        // An unrelated write must leave the one-shot observation armed.
        XCTAssertEqual(invalidations.withLock { $0 }, 0)
        let secondWindow = ComputerUseMonitorWindow(id: firstWindow.id, title: "Second")
        appState.sessionStates[session]?.computerUseWindows = [secondWindow]
        XCTAssertEqual(invalidations.withLock { $0 }, 1)
        XCTAssertEqual(appState.computerUseMonitors(forSession: session), [secondWindow])
    }

    func testPreviewFollowsSessionReplacementAndCompletion() {
        let preview = ComputerUseMonitorWindow(id: .native(appID: "test"), title: "Window")
        var state = streamState(isStreaming: true)
        state.computerUseWindows = [preview]
        appState.sessionStates["pending"] = state
        appState.sessionStates = ["resolved": state]
        XCTAssertTrue(appState.computerUseMonitors(forSession: "pending").isEmpty)
        XCTAssertEqual(appState.computerUseMonitors(forSession: "resolved"), [preview])
        appState.sessionStates["resolved"]?.isStreaming = false
        XCTAssertTrue(appState.computerUseMonitors(forSession: "resolved").isEmpty)
    }

    func testProjectAttentionRefreshesAfterSessionRedirectAndRemoval() {
        let project = makeProject("Attention")
        let otherProject = makeProject("Other Project")
        let previousID = "previous-attention-session"
        let currentID = "current-attention-session"
        let summary = ChatSession(id: previousID, projectId: project.id).summary
        let otherSummary = ChatSession(id: "other-attention-session", projectId: otherProject.id).summary
        appState.allSessionSummaries = [summary, otherSummary]
        appState.sessionStates = [
            currentID: streamState(isStreaming: true),
            otherSummary.id: streamState(isStreaming: true),
        ]

        XCTAssertEqual(appState.projectAttention(projectId: project.id, in: window).runningThreads, 0)
        appState.sessionIdRedirect[previousID] = currentID
        XCTAssertEqual(appState.projectAttention(projectId: project.id, in: window).runningThreads, 1)
        appState.allSessionSummaries = [otherSummary]
        XCTAssertEqual(appState.projectAttention(projectId: project.id, in: window).runningThreads, 0)
        XCTAssertEqual(appState.projectAttention(projectId: otherProject.id, in: window).runningThreads, 1)
    }

    func testCachedTaskLinksFollowBoardOrderEditsRedirectsAndRemoval() {
        let project = UUID()
        var source = ProjectTask(projectId: project, title: "Source", sourceSessionKey: "shared")
        let run = ProjectTask(projectId: project, title: "Run", sessionKey: "pending-run")
        appState.taskBoards[project] = TaskBoard(tasks: [source, run])
        XCTAssertEqual(appState.linkedTask(forSessionId: "shared", projectId: project)?.id, source.id)

        appState.sessionIdRedirect["pending-run"] = "shared"
        XCTAssertEqual(appState.linkedTask(forSessionId: "pending-run", projectId: project)?.id, source.id)
        appState.taskBoards[project]?.tasks.swapAt(0, 1)
        XCTAssertEqual(appState.linkedTask(forSessionId: "shared", projectId: project)?.id, run.id)
        source.title = "Updated source"
        appState.taskBoards[project]?.tasks = [source]
        XCTAssertEqual(appState.linkedTask(forSessionId: "shared", projectId: project)?.title, source.title)
        appState.taskBoards[project] = nil
        XCTAssertNil(appState.linkedTask(forSessionId: "shared", projectId: project))
    }

    func testBackgroundTodoRefreshTracksReplacementsAndRemovals() async {
        let todo = MessageBlock.toolCall(ToolCall(id: "todo", name: "TodoWrite", input: [
            "todos": .array([.object(["content": .string("Build"), "status": .string("pending")])]),
        ]))
        var state = SessionStreamState()
        state.messages = [ChatMessage(role: .assistant, blocks: [todo])]
        appState.sessionStates["kept"] = state
        appState.sessionStates["removed"] = state
        appState.sessionStates["removed"] = nil
        await appState.sessionActivityTodoRefreshTask?.value
        XCTAssertEqual(appState.liveTodos(forSessionId: "kept")?.items.map(\.content), ["Build"])
        XCTAssertNil(appState.sessionActivity["removed"])

        appState.sessionStates["kept"]?.messages = []
        await appState.sessionActivityTodoRefreshTask?.value
        XCTAssertNil(appState.liveTodos(forSessionId: "kept"))
    }

    func testMobileSummariesUseTheNewestTodoListIncludingClears() async throws {
        let project = makeProject("Todo Sync")
        let session = ChatSession(id: UUID().uuidString, projectId: project.id)
        appState.projects = [project]
        appState.allSessionSummaries = [session.summary]

        appState.threadStore.upsertTodoSnapshot(sessionId: session.id, items: [])
        defer { appState.threadStore.deleteTodoSnapshot(sessionId: session.id) }
        let updatedAt = try XCTUnwrap(appState.threadStore.fetchTodoSnapshot(sessionId: session.id)?.updatedAt)
        let todo = MessageBlock.toolCall(ToolCall(id: "todos", name: "TodoWrite", input: [
            "todos": .array([.object(["content": .string("Verify build"), "status": .string("in_progress")])]),
        ]))
        var state = SessionStreamState()
        state.messages = [ChatMessage(role: .assistant, blocks: [todo], timestamp: updatedAt.addingTimeInterval(-1))]
        appState.sessionStates[session.id] = state

        XCTAssertEqual(appState.mobileSessionSummary(for: session.id)?.todos, [])
        let afterClear = await appState.mobileSessionSummaries()
        XCTAssertEqual(afterClear.first?.todos, [])

        state.messages = [ChatMessage(role: .assistant, blocks: [todo], timestamp: updatedAt.addingTimeInterval(1))]
        appState.sessionStates[session.id] = state

        XCTAssertEqual(appState.mobileSessionSummary(for: session.id)?.todos?.map(\.content), ["Verify build"])
        let afterUpdate = await appState.mobileSessionSummaries()
        XCTAssertEqual(afterUpdate.first?.todos?.map(\.content), ["Verify build"])
    }

    func testMobileSnapshotLoadsSavedAgentConversationsAndSubagentHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        appState.persistence = PersistenceService(metaStore: appState.metaStore, cliStore: appState.cliStore, baseURL: root)
        let agent = AgentProfile(name: "Mobile history")
        appState.agentProfiles = [agent]
        let messages = (0...AppState.mobileMessagePageSize).map { ChatMessage(role: .user, content: "Message \($0)") }
        let conversation = ChatSession(id: "conversation", projectId: agent.id, messages: messages, origin: .codexAppServer)
        let subagent = ChatSession(id: "subagent", projectId: agent.subagentProjectId,
                                   messages: [ChatMessage(role: .assistant, content: "Job finished")], origin: .acpAgent)
        appState.allSessionSummaries = [conversation.summary, subagent.summary]
        // A thread can have runtime metadata before its transcript has been opened on the Mac.
        appState.sessionStates[subagent.id] = SessionStreamState()
        for session in [conversation, subagent] {
            try await appState.persistence.saveSession(session)
            let page = await appState.mobileActiveSessionPayload(for: session.id)
            XCTAssertEqual(page.id, session.id)
            XCTAssertEqual(page.messages?.map(\.id), session.messages.suffix(AppState.mobileMessagePageSize).map(\.id))
            XCTAssertEqual(page.hasMore, session.messages.count > AppState.mobileMessagePageSize)
        }
    }

    func testMobileSnapshotDistinguishesMissingHistoryFromAnEmptyThreadAndABroadcast() async {
        let project = makeProject("History")
        let missing = ChatSession(id: "missing", projectId: project.id)
        let empty = ChatSession(id: "empty", projectId: project.id)
        let placeholder = ChatSession(id: "pending-mobile-\(UUID().uuidString)", projectId: project.id)
        appState.projects = [project]
        appState.allSessionSummaries = [missing.summary, empty.summary, placeholder.summary]
        await persistence.stubFullSession(empty)

        let unavailable = await appState.mobileActiveSessionPayload(for: missing.id)
        XCTAssertEqual(unavailable.id, missing.id)
        XCTAssertNil(unavailable.messages)
        let loaded = await appState.mobileActiveSessionPayload(for: empty.id)
        XCTAssertEqual(loaded.id, empty.id)
        XCTAssertEqual(loaded.messages, [])
        let pending = await appState.mobileActiveSessionPayload(for: placeholder.id)
        XCTAssertEqual(pending.messages, [])
        let broadcast = await appState.mobileActiveSessionPayload(for: nil)
        XCTAssertNil(broadcast.id)
        XCTAssertNil(broadcast.messages)
    }

    func testMobileTaskSnapshotResolvesLinksAndReviewFeedback() async {
        let project = makeProject("Board")
        appState.projects = [project]
        appState.sessionIdRedirect = ["pending-run": "previous-run", "previous-run": "run", "pending-source": "source"]
        let task = ProjectTask(
            projectId: project.id, title: "Linked", sessionKey: "pending-run", sourceSessionKey: "pending-source"
        )
        let sameSource = ProjectTask(
            projectId: project.id, title: "Same run and source", sessionKey: "pending-run", sourceSessionKey: "run"
        )
        let missing = ProjectTask(projectId: project.id, title: "Missing", sessionKey: "missing")
        let unlinked = ProjectTask(projectId: project.id, title: "Unlinked")
        appState.taskBoards[project.id] = TaskBoard(tasks: [task, sameSource, missing, unlinked])

        let date = Date(timeIntervalSince1970: 1)
        let run = ChatSession(id: "run", projectId: project.id, title: "Run", updatedAt: date)
        let source = ChatSession(
            id: "source", projectId: project.id, title: "Source", updatedAt: date, parentThreadId: "previous-run"
        )
        let review = ChatSession(
            id: "review",
            projectId: project.id,
            messages: [ChatMessage(role: .assistant, content: "Looks good"), ChatMessage(role: .assistant, content: " ")],
            updatedAt: date.addingTimeInterval(1),
            parentThreadId: "pending-run",
            threadLabel: "Code Review"
        )
        let unrelated = ChatSession(id: "unrelated", projectId: project.id)
        appState.allSessionSummaries = [review.summary, source.summary, unrelated.summary, run.summary]
        await persistence.stubFullSession(review)

        let snapshot = await appState.mobileTaskBoardSnapshot(for: project.id)
        XCTAssertEqual(snapshot.taskSessionIDs, [task.id.uuidString: "run", sameSource.id.uuidString: "run"])
        XCTAssertEqual(snapshot.taskLinkedSessions[task.id.uuidString], [
            MobileTaskLinkedSession(id: "source", title: "Source", kind: .source),
            MobileTaskLinkedSession(id: "run", title: "Run", kind: .run),
            MobileTaskLinkedSession(id: "review", title: "Code Review", kind: .review, feedback: "Looks good"),
        ])
        XCTAssertEqual(snapshot.taskLinkedSessions[sameSource.id.uuidString]?.map(\.id), ["source", "run", "review"])
        XCTAssertEqual(snapshot.taskLinkedSessions[missing.id.uuidString], [])
        XCTAssertEqual(snapshot.taskLinkedSessions[unlinked.id.uuidString], [])
    }

    private func makeProject(_ name: String) -> Project {
        Project(name: name, path: "/tmp/\(name.lowercased())", gitHubRepo: nil)
    }

    private func streamState(isStreaming: Bool) -> SessionStreamState {
        var state = SessionStreamState()
        state.isStreaming = isStreaming
        return state
    }
}
