import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class MemoryIntentTests: XCTestCase {
    func testPreferenceMemoryInjectsIntoSystemPrompt() {
        XCTAssertTrue(
            AppState.fallbackShouldInjectMemoryIntoSystemPrompt(memory(content: "Use English for project text.", kind: "preference"))
        )
    }

    func testAlwaysFactMemoryInjectsIntoSystemPrompt() {
        XCTAssertTrue(
            AppState.fallbackShouldInjectMemoryIntoSystemPrompt(memory(content: "Always run make lint before finishing.", kind: "fact"))
        )
    }

    func testRoutineFactMemoryDoesNotInjectIntoSystemPrompt() {
        XCTAssertFalse(
            AppState.fallbackShouldInjectMemoryIntoSystemPrompt(memory(content: "Added Makefile lint commands.", kind: "fact"))
        )
    }

    func testParsesMemoryInjectionDecision() {
        XCTAssertEqual(AppState.parseMemoryInjectionDecision("true"), true)
        XCTAssertEqual(AppState.parseMemoryInjectionDecision("false"), false)
        XCTAssertNil(AppState.parseMemoryInjectionDecision("maybe"))
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
