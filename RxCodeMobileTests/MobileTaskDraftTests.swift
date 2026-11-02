import Foundation
import RxCodeCore
import XCTest
@testable import RxCodeMobile

@MainActor
final class MobileTaskDraftTests: XCTestCase {
    func testPromptRequestsDraftAndClassificationTogether() {
        let source = "Fix mobile task creation. Bug, urgent, v2.0.0, medium size."
        let prompt = MobileTaskDraftService.prompt(source: source, board: TaskBoard(), kind: .task,
                                                  storyTitle: nil, candidates: ["Ship the API"])
        XCTAssertTrue(prompt.contains(source))
        XCTAssertTrue(prompt.contains(#"{"title": string, "details": string, "type": string|null"#))
        XCTAssertTrue(prompt.contains("[urgent, high, medium, low]"))
        XCTAssertTrue(prompt.contains("[xs, s, m, l, xl]"))
        XCTAssertTrue(prompt.contains("Ship the API"))
        XCTAssertTrue(prompt.contains("Do not save anything or call tools."))
    }

    func testDraftFillsClassificationAndPreservesFormChoices() throws {
        let draft = try MobileTaskDraft.parse(#"```json {"title":"Fix mobile task creation","details":"Support both AI providers.","type":"Bug","priority":"urgent","version":"v2.0.0","size":"m"} ```"#)
        let board = TaskBoard()
        var task = ProjectTask(projectId: UUID(), title: draft.title)
        draft.classification.apply(to: &task, board: board)
        XCTAssertEqual(board.effectiveTypes.first { $0.id == task.typeId }?.name, "Bug")
        XCTAssertEqual(task.priority, .urgent)
        XCTAssertEqual(task.version, "v2.0.0")
        XCTAssertEqual(task.size, .m)
        task.priority = .low
        task.version = "v3.0.0"
        task.size = .s
        draft.classification.apply(to: &task, board: board)
        XCTAssertEqual(task.priority, .low)
        XCTAssertEqual(task.version, "v3.0.0")
        XCTAssertEqual(task.size, .s)
        var story = ProjectStory(projectId: task.projectId, title: draft.title)
        draft.classification.apply(to: &story, board: board)
        XCTAssertEqual(story.priority, .urgent)
        XCTAssertEqual(story.size, .m)
    }

    func testInvalidDraftCannotBeApplied() {
        for text in ["No response", #"{"title":" ","details":"Description"}"#, #"{"title":"Fix it"}"#,
                     #"{"title":"Fix it","details":"Missing classification"}"#] {
            XCTAssertThrowsError(try MobileTaskDraft.parse(text))
        }
    }

    func testFlowcyDraftAndFailuresOverHTTP() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FLOWCY_SIMULATION"] == "1", "Requires the Flowcy simulation.")
        let api = FlowcyAPI(baseURL: URL(string: FlowcySimulation.baseURL)!, token: { _ in "simulation" })
        let prompt = MobileTaskDraftService.prompt(source: "Fix mobile task creation. Bug, urgent, v2.0.0, medium size.",
                                                 board: TaskBoard(), kind: .task, storyTitle: nil, candidates: [])
        let draft = try await MobileTaskDraftService.flowcy(prompt: prompt, api: api)
        XCTAssertEqual(draft.title, "Fix mobile task creation")
        XCTAssertEqual(draft.classification.priority, "urgent")
        XCTAssertEqual(draft.classification.version, "v2.0.0")
        XCTAssertEqual(draft.classification.size, "m")
        for failure in ["HTTPFailure", "Interrupted", "StreamFailure", "UnexpectedTool"] {
            do {
                _ = try await MobileTaskDraftService.flowcy(prompt: prompt + "\n" + failure, api: api)
                XCTFail("Expected \(failure) to fail without a usable draft")
            } catch { }
        }
    }
}
