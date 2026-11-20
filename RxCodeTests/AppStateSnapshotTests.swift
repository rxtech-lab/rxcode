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
