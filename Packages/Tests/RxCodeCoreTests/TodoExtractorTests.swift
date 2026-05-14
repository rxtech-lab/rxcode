import Testing
@testable import RxCodeCore

@Suite("Todo extraction")
struct TodoExtractorTests {

    @Test("Codex plan update maps steps to todos")
    func codexPlanUpdateMapsStepsToTodos() {
        let todos = TodoExtractor.parseCodexPlanUpdate(params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1"),
            "plan": .array([
                .object([
                    "step": .string("Inspect app-server schema"),
                    "status": .string("completed")
                ]),
                .object([
                    "step": .string("Wire plan updates into todo UI"),
                    "status": .string("inProgress")
                ]),
                .object([
                    "step": .string("Run focused tests"),
                    "status": .string("pending")
                ])
            ])
        ])

        #expect(todos == [
            TodoItem(id: 0, content: "Inspect app-server schema", activeForm: "Inspect app-server schema", status: .completed),
            TodoItem(id: 1, content: "Wire plan updates into todo UI", activeForm: "Wire plan updates into todo UI", status: .inProgress),
            TodoItem(id: 2, content: "Run focused tests", activeForm: "Run focused tests", status: .pending)
        ])
    }

    @Test("Missing Codex plan returns nil")
    func missingCodexPlanReturnsNil() {
        let todos = TodoExtractor.parseCodexPlanUpdate(params: [
            "threadId": .string("thread-1"),
            "turnId": .string("turn-1")
        ])

        #expect(todos == nil)
    }
}
