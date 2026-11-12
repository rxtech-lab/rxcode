import Testing
@testable import RxCodeCore

@Suite("MCP tool calls")
struct MCPToolCallTests {

    @Test("IDE questions remain available for every provider and capability set")
    func questionsAreAvailableOutsideNativeQuestionModes() throws {
        let capabilitySets = AgentProvider.allCases.map(\.staticCapabilities)
            + [CapabilitySet(), CapabilitySet(BackendCapability.allCases)]
        for capabilities in capabilitySets {
            let tool = try #require(IDEToolRegistry.tools(for: capabilities).first {
                $0.name == "ide__ask_user"
            })
            #expect(tool.inputSchema["required"]?.arrayValue == [.string("question"), .string("options")])
            // Todo polyfills should still respect native backend support.
            #expect(IDEToolRegistry.tools(for: capabilities).contains {
                $0.name == "ide__set_todos"
            } == !capabilities.contains(.todos))
        }
    }

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

    @Test("Task mutation tools are exposed to every backend and require a task id")
    func taskMutationToolsAreAvailable() throws {
        for capabilities: Set<BackendCapability> in [[], [.askUserQuestion]] {
            let tools = IDEToolRegistry.tools(for: capabilities)
            for name in ["ide__update_task", "ide__delete_task"] {
                let tool = try #require(tools.first { $0.name == name })
                #expect(tool.inputSchema["required"]?.arrayValue == [.string("task_id")])
                #expect(tool.inputSchema["properties"]?["task_id"]?["type"] == .string("string"))
            }
        }
    }

    @Test("Agent discovery and task assignment schemas are available")
    func agentDiscoverySchema() throws {
        let tools = IDEToolRegistry.tools(for: [])
        let discovery = try #require(tools.first { $0.name == "ide__list_agent_models" })
        #expect(discovery.inputSchema["properties"]?.objectValue?.isEmpty == true)
        let update = try #require(tools.first { $0.name == "ide__update_task" })
        for field in ["provider", "model"] {
            #expect(update.inputSchema["properties"]?[field]?["type"]?.arrayValue == [.string("string"), .string("null")])
        }
    }

    @Test("Memory tools use search instead of a get-by-id tool")
    func memoryToolsUseSearch() {
        let names = Set(IDEToolRegistry.allTools.map(\.name))

        #expect(names.contains("ide__memory_search"))
        #expect(!names.contains("ide__memory_get"))
    }
}
