import Testing
@testable import RxCodeCore

@Suite("MCP tool calls")
struct MCPToolCallTests {

    @Test("Generic Codex MCP tool calls are categorized as MCP")
    func genericCodexMCPToolCallCategory() {
        #expect(ToolCategory(toolName: "mcpToolCall") == .mcp)
    }

    @Test("Completed MCP calls with empty output are retained")
    func emptySuccessfulMCPResultIsRetained() {
        var message = ChatMessage(role: .assistant)
        message.appendToolCall(ToolCall(
            id: "mcp-1",
            name: "mcpToolCall",
            input: ["query": .string("saved preferences")]
        ))

        message.setToolResult(id: "mcp-1", result: "", isError: false)
        message.finalizeToolCalls()

        #expect(message.toolCalls.count == 1)
        #expect(message.toolCalls.first?.isError == false)
        #expect(message.toolCalls.first?.result == "")
    }
}
