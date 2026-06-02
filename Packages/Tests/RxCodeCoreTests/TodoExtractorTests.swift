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

    // MARK: - Task tools (TaskCreate / TaskUpdate)

    private func taskCreate(id: Int, subject: String, activeForm: String? = nil) -> MessageBlock {
        var input: [String: JSONValue] = ["subject": .string(subject), "description": .string(subject)]
        if let activeForm { input["activeForm"] = .string(activeForm) }
        return .toolCall(ToolCall(
            id: "tc-\(id)",
            name: "TaskCreate",
            input: input,
            result: "Task #\(id) created successfully: \(subject)"
        ))
    }

    private func taskUpdate(id: Int, status: String) -> MessageBlock {
        .toolCall(ToolCall(
            id: "tu-\(id)-\(status)",
            name: "TaskUpdate",
            input: ["taskId": .string("\(id)"), "status": .string(status)],
            result: "Task #\(id) updated"
        ))
    }

    private func message(_ blocks: [MessageBlock]) -> ChatMessage {
        ChatMessage(role: .assistant, blocks: blocks)
    }

    @Test("TaskCreate calls reconstruct a pending todo list")
    func taskCreateReconstructsList() {
        let todos = TodoExtractor.latest(in: [
            message([
                taskCreate(id: 1, subject: "Autopilot protocol layer", activeForm: "Building protocol layer"),
                taskCreate(id: 2, subject: "Build & verify Android app")
            ])
        ])

        #expect(todos == [
            TodoItem(id: 1, content: "Autopilot protocol layer", activeForm: "Building protocol layer", status: .pending),
            TodoItem(id: 2, content: "Build & verify Android app", activeForm: "Build & verify Android app", status: .pending)
        ])
    }

    @Test("TaskUpdate replays status transitions and preserves creation order")
    func taskUpdateAppliesStatus() {
        let todos = TodoExtractor.latest(in: [
            message([
                taskCreate(id: 1, subject: "First"),
                taskCreate(id: 2, subject: "Second"),
                taskCreate(id: 3, subject: "Third")
            ]),
            message([
                taskUpdate(id: 1, status: "completed"),
                taskUpdate(id: 2, status: "in_progress")
            ])
        ])

        #expect(todos == [
            TodoItem(id: 1, content: "First", activeForm: "First", status: .completed),
            TodoItem(id: 2, content: "Second", activeForm: "Second", status: .inProgress),
            TodoItem(id: 3, content: "Third", activeForm: "Third", status: .pending)
        ])
    }

    @Test("TaskUpdate deleted removes the task")
    func taskDeleteRemovesTask() {
        let todos = TodoExtractor.latest(in: [
            message([
                taskCreate(id: 1, subject: "Keep"),
                taskCreate(id: 2, subject: "Drop")
            ]),
            message([taskUpdate(id: 2, status: "deleted")])
        ])

        #expect(todos == [
            TodoItem(id: 1, content: "Keep", activeForm: "Keep", status: .pending)
        ])
    }

    @Test("TaskCreate without a result yet is skipped until its id lands")
    func taskCreateWithoutResultSkipped() {
        let pending = MessageBlock.toolCall(ToolCall(
            id: "tc-pending",
            name: "TaskCreate",
            input: ["subject": .string("Not ready"), "description": .string("Not ready")],
            result: nil
        ))
        let todos = TodoExtractor.fromTaskTools(in: [message([pending])])

        #expect(todos == nil)
    }

    @Test("TodoWrite takes precedence over task tools when both present")
    func todoWriteWins() {
        let todos = TodoExtractor.latest(in: [
            message([taskCreate(id: 1, subject: "Task-tool item")]),
            message([
                .toolCall(ToolCall(
                    id: "todo-1",
                    name: "TodoWrite",
                    input: ["todos": .array([
                        .object([
                            "content": .string("TodoWrite item"),
                            "status": .string("pending")
                        ])
                    ])]
                ))
            ])
        ])

        #expect(todos == [
            TodoItem(id: 0, content: "TodoWrite item", activeForm: "TodoWrite item", status: .pending)
        ])
    }
}
