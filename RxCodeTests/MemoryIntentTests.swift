import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class MemoryIntentTests: XCTestCase {
    func testRoutineTaskDoesNotAllowAutomaticMemoryExtraction() {
        XCTAssertFalse(
            AppState.hasExplicitMemoryIntent("Run make lint and fix the warnings.")
        )
    }

    func testTaskResultDoesNotAllowAgentMemoryAdd() {
        XCTAssertFalse(
            AppState.shouldAcceptAgentMemoryAdd(
                content: "Added Makefile to include make lint and make lint-ci commands.",
                kind: "fact"
            )
        )
    }

    func testRememberRequestAllowsAutomaticMemoryExtraction() {
        XCTAssertTrue(
            AppState.hasExplicitMemoryIntent("Please remember to use English for project text.")
        )
    }

    func testFutureInstructionAllowsAutomaticMemoryExtraction() {
        XCTAssertTrue(
            AppState.hasExplicitMemoryIntent("From now on, run make lint before finishing.")
        )
    }

    func testPreferenceAllowsAutomaticMemoryExtraction() {
        XCTAssertTrue(
            AppState.hasExplicitMemoryIntent("I prefer concise final answers.")
        )
    }

    func testPreferenceKindAllowsAgentMemoryAdd() {
        XCTAssertTrue(
            AppState.shouldAcceptAgentMemoryAdd(
                content: "Use English for project text.",
                kind: "preference"
            )
        )
    }

    func testExplicitFutureInstructionAllowsAgentMemoryAddEvenAsFact() {
        XCTAssertTrue(
            AppState.shouldAcceptAgentMemoryAdd(
                content: "Always run make lint before finishing.",
                kind: "fact"
            )
        )
    }

    func testPreferenceMemoryInjectsIntoSystemPrompt() {
        XCTAssertTrue(
            AppState.shouldInjectMemoryIntoSystemPrompt(memory(content: "Use English for project text.", kind: "preference"))
        )
    }

    func testAlwaysFactMemoryInjectsIntoSystemPrompt() {
        XCTAssertTrue(
            AppState.shouldInjectMemoryIntoSystemPrompt(memory(content: "Always run make lint before finishing.", kind: "fact"))
        )
    }

    func testRoutineFactMemoryDoesNotInjectIntoSystemPrompt() {
        XCTAssertFalse(
            AppState.shouldInjectMemoryIntoSystemPrompt(memory(content: "Added Makefile lint commands.", kind: "fact"))
        )
    }

    private func memory(content: String, kind: String) -> MemoryItem {
        MemoryItem(
            id: UUID().uuidString,
            content: content,
            projectId: nil,
            sessionId: nil,
            sourceMessageId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            lastUsedAt: nil,
            kind: kind,
            scope: "global"
        )
    }
}
