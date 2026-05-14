import Testing
@testable import RxCodeCore

@Suite("ChatMessage tool-result retention")
struct ChatMessageToolResultTests {

    @Test("Completed Bash with empty output is retained for collapsed summaries")
    func emptyBashResultIsRetained() {
        var message = ChatMessage(role: .assistant)
        message.appendToolCall(ToolCall(
            id: "bash-1",
            name: "Bash",
            input: ["command": .string("true")]
        ))

        message.setToolResult(id: "bash-1", result: "", isError: false)
        message.finalizeToolCalls()

        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.result == "")
    }

    @Test("Unresolved Bash is removed on final cleanup")
    func unresolvedBashIsRemoved() {
        var message = ChatMessage(role: .assistant)
        message.appendToolCall(ToolCall(
            id: "bash-1",
            name: "Bash",
            input: ["command": .string("sleep 1")]
        ))

        message.finalizeToolCalls()

        #expect(message.toolCalls.isEmpty)
    }

    @Test("Unknown tool with empty success is still removed")
    func emptyUnknownToolResultIsRemoved() {
        var message = ChatMessage(role: .assistant)
        message.appendToolCall(ToolCall(id: "custom-1", name: "CustomTool"))

        message.setToolResult(id: "custom-1", result: "", isError: false)

        #expect(message.toolCalls.isEmpty)
    }
}
