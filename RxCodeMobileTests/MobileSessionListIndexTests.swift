import XCTest
import Combine
import RxCodeCore
import RxCodeSync
@testable import RxCodeMobile

@MainActor
final class MobileSessionListIndexTests: XCTestCase {
    private let projectID = UUID()

    func testRepeatedThinkingFlagsDoNotInvalidateChat() {
        let state = MobileAppState()
        var publications = 0
        let observation = state.$thinkingSessions.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }

        state.setSessionThinking(sessionID: "chat", isThinking: false)
        XCTAssertEqual(publications, 0)
        state.setSessionThinking(sessionID: "chat", isThinking: true)
        state.setSessionThinking(sessionID: "chat", isThinking: true)
        XCTAssertEqual(publications, 1)
        state.setSessionThinking(sessionID: "chat", isThinking: false)
        state.setSessionThinking(sessionID: "chat", isThinking: false)
        XCTAssertEqual(publications, 2)
    }

    func testUnchangedStreamMessageDoesNotRepublishHistory() {
        let state = MobileAppState()
        let message = ChatMessage(role: .assistant, content: "First token", isStreaming: true)
        state.messagesBySession["chat"] = [message]
        var publications = 0
        let observation = state.$messagesBySession.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }

        state.applySessionUpdate(.init(sessionID: "chat", kind: .messageUpdated, message: message))
        XCTAssertEqual(publications, 0)

        var updated = message
        updated.blocks[0].text = "First token and more"
        state.applySessionUpdate(.init(sessionID: "chat", kind: .messageUpdated, message: updated))
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(state.messages(sessionID: "chat"), [updated])

        updated.isStreaming = false
        state.applySessionUpdate(.init(sessionID: "chat", kind: .messageUpdated, message: updated))
        XCTAssertEqual(publications, 2)
        XCTAssertFalse(state.messages(sessionID: "chat")[0].isStreaming)
    }

    private func session(_ id: String, time: Double = 1, pinned: Bool = false,
                         archived: Bool = false, parent: String? = nil,
                         project: UUID? = nil) -> SessionSummary {
        SessionSummary(id: id, projectId: project ?? projectID, title: id,
                       updatedAt: Date(timeIntervalSince1970: time), isPinned: pinned,
                       isArchived: archived, isStreaming: archived,
                       parentThreadId: parent, threadLabel: parent == nil ? nil : "Code Review",
                       changedFileCount: 3)
    }

    func testCountsOrderingAndReviewFallback() throws {
        let index = MobileSessionListIndex(sessions: [
            session("parent", time: 4), session("pinned", pinned: true),
            session("review2", time: 3, parent: "parent"),
            session("review1", time: 2, parent: "parent"),
            session("archived", time: 9, archived: true),
            session("orphan", parent: "archived"),
            session("other", project: UUID())
        ])
        let rows = try XCTUnwrap(index.projects[projectID])
        XCTAssertEqual(rows.threadCount, 5)
        XCTAssertEqual(rows.activeJobCount, 1)
        XCTAssertEqual(rows.lastActivity, Date(timeIntervalSince1970: 9))
        XCTAssertEqual(rows.roots.map(\.id), ["pinned", "parent", "orphan"])
        XCTAssertEqual(rows.children["parent"]?.map(\.id), ["review1", "review2"])
    }

    func testIndexTracksReplacementRemovalAndStreamingMetadata() {
        let state = MobileAppState()
        state.sessions = [session("parent"), session("review", parent: "parent")]
        state.updateSessionStreamingFlag(sessionID: "review", isStreaming: true)
        let rows = state.sessionListIndex.projects[projectID]
        XCTAssertEqual(rows?.activeJobCount, 1)
        XCTAssertEqual(rows?.children["parent"]?.first?.threadLabel, "Code Review")
        XCTAssertEqual(rows?.children["parent"]?.first?.changedFileCount, 3)
        state.sessions.removeAll { $0.id == "parent" }
        XCTAssertEqual(state.sessionListIndex.projects[projectID]?.roots.map(\.id), ["review"])
        state.sessions = []
        XCTAssertTrue(state.sessionListIndex.projects.isEmpty)
    }

    func testLargeHistoryPreservesEveryVisibleThread() {
        let sessions = (0..<5_000).map { session("thread-\($0)", time: Double($0)) }
        let index = MobileSessionListIndex(sessions: sessions)
        XCTAssertEqual(index.projects[projectID]?.roots.count, 5_000)
        XCTAssertEqual(index.projects[projectID]?.roots.first?.id, "thread-4999")
    }
}
