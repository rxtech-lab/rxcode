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

    @Test("Unresolved Bash is retained across mid-turn message splits and removed on final cleanup")
    func unresolvedBashSurvivesMidTurnSplitThenRemovedAtStreamEnd() {
        var message = ChatMessage(role: .assistant)
        message.appendToolCall(ToolCall(
            id: "exec-1",
            name: "Bash",
            input: ["command": .string("/bin/zsh -lc 'python3 patch.py'")]
        ))

        // Mid-turn split (`needsNewMessage` while parallel `exec-1` is still running)
        // must keep `exec-1` so its delayed `tool_result` can match and run shell diff detection.
        message.finalizeToolCalls(dropIncomplete: false)
        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.result == nil)

        // End-of-stream cleanup removes any remaining unresolved non-keepAlways tool calls.
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
