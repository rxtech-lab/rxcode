import XCTest
import RxCodeCore
@testable import RxCode

/// Coverage for the per-card hook persistence sidecar (`HookCardRecord`): cards
/// survive a reload with their full payload, status updates preserve that
/// payload, and both per-session and project-scoped deletes clean up the rows.
@MainActor
final class ThreadStoreHookCardTests: XCTestCase {

    // `ThreadStore` is `@MainActor`, so its synthesized deinit hops executors via
    // the Swift concurrency runtime — which double-frees when a local store
    // deallocates at a test's return (an XCTest/NSInvocation teardown artifact;
    // in the real app the store lives for the whole process and never deinits).
    // Retain every store created here for the test process so that deinit never
    // runs mid-run.
    private static var retainedStores: [ThreadStore] = []
    private func makeStore() -> ThreadStore {
        let store = ThreadStore.inMemory()
        Self.retainedStores.append(store)
        return store
    }

    private func reviewCardInput(_ summary: String) -> [String: JSONValue] {
        [
            "name": .string("Code Review"),
            "trigger": .string("After Session Stop"),
            "summary": .string(summary),
        ]
    }

    private func decodedInput(_ record: HookCardRecord) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: record.inputData)
    }

    func testHookCardsRebuildInInsertionOrderWithFullPayload() throws {
        let store = makeStore()
        let sid = "sess-cards"

        store.upsertHookCard(
            sessionId: sid, toolId: "t1", toolName: "Hook: Code Review",
            input: reviewCardInput("3 changed file(s)"),
            result: nil, isError: false, isComplete: false
        )
        store.upsertHookCard(
            sessionId: sid, toolId: "t2", toolName: ToolCall.autoContinueToolName,
            input: ["summary": .string("continuing")],
            result: "addressed", isError: false, isComplete: true
        )

        let cards = store.loadHookCards(sessionId: sid)
        XCTAssertEqual(cards.map(\.toolId), ["t1", "t2"], "oldest-first by createdAt")

        // The full inserted payload (including `summary`) round-trips, so the
        // rebuilt card carries the same info it was inserted with.
        XCTAssertEqual(try decodedInput(cards[0])["summary"], .string("3 changed file(s)"))
        XCTAssertNil(cards[0].result, "in-progress card has no result yet")
        XCTAssertFalse(cards[0].isComplete)
        XCTAssertEqual(cards[1].result, "addressed")
    }

    func testCompleteHookCardPreservesToolNameAndInput() throws {
        let store = makeStore()
        let sid = "sess-complete"

        store.upsertHookCard(
            sessionId: sid, toolId: "t1", toolName: "Hook: Code Review",
            input: reviewCardInput("2 changed file(s)"),
            result: nil, isError: false, isComplete: false
        )

        // Mirrors the controller's `persistHookStatus` path: only status fields
        // change; `toolName`/`input` must be preserved (regression for the bug
        // where the legacy payload clobbered the inserted one).
        XCTAssertTrue(store.completeHookCard(toolId: "t1", result: "✅ passed", isError: false, isComplete: true))

        let card = try XCTUnwrap(store.loadHookCards(sessionId: sid).first)
        XCTAssertEqual(card.toolName, "Hook: Code Review")
        XCTAssertEqual(card.result, "✅ passed")
        XCTAssertTrue(card.isComplete)
        XCTAssertEqual(try decodedInput(card)["summary"], .string("2 changed file(s)"))

        // No matching row → no-op, reported via `false` so callers can fall back.
        XCTAssertFalse(store.completeHookCard(toolId: "missing", result: "x", isError: false))
    }

    func testDeletingSessionRemovesHookCards() {
        let store = makeStore()
        let sid = "sess-del"
        store.context.insert(ChatThread(id: sid, projectId: UUID()))
        store.save()
        store.upsertHookCard(
            sessionId: sid, toolId: "t1", toolName: "x", input: [:],
            result: "r", isError: false, isComplete: true
        )
        XCTAssertEqual(store.loadHookCards(sessionId: sid).count, 1)

        store.delete(id: sid)
        XCTAssertTrue(store.loadHookCards(sessionId: sid).isEmpty, "session delete must not leak hook cards")
    }

    func testProjectScopedDeleteAllRemovesHookCards() {
        let store = makeStore()
        let projectId = UUID()
        let sid = "sess-proj-del"
        store.context.insert(ChatThread(id: sid, projectId: projectId))
        store.save()
        store.upsertHookCard(
            sessionId: sid, toolId: "t1", toolName: "x", input: [:],
            result: "r", isError: false, isComplete: true
        )
        XCTAssertEqual(store.loadHookCards(sessionId: sid).count, 1)

        store.deleteAll(projectId: projectId)
        XCTAssertTrue(store.loadHookCards(sessionId: sid).isEmpty, "project delete must not leak hook cards")
    }
}
