import Testing
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("MCP tool result view")
struct MCPToolResultViewTests {

    private struct Host: View {
        let window = WindowState()
        let toolCall: ToolCall

        var body: some View {
            ToolResultView(toolCall: toolCall, isMessageStreaming: false)
                .environment(window)
        }
    }

    @Test("Tapping an MCP row is handled and the detail sheet renders JSON params and result")
    func tappingMCPRowAndRenderingDetailSheet() throws {
        let toolCall = makeMCPToolCall()
        let view = Host(toolCall: toolCall)
        ViewHosting.host(view: view)
        defer { ViewHosting.expel() }

        try view.inspect().find(ViewType.Button.self).tap()

        let detail = MCPToolDetailSheet(toolCall: toolCall)
        let labels = try detail.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(labels.contains("Call Params"))
        #expect(labels.contains("Result"))
        #expect(labels.contains { $0.contains("\"query\"") })
        #expect(labels.contains { $0.contains("\"ok\"") })
    }

    @Test("MCP detail sheet renders inside a narrow host")
    func detailSheetRendersInsideNarrowHost() throws {
        let detail = MCPToolDetailSheet(toolCall: makeMCPToolCall())
            .frame(width: 320, height: 560)
        ViewHosting.host(view: detail)
        defer { ViewHosting.expel() }

        let labels = try detail.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        #expect(labels.contains("MCP tool call"))
        #expect(labels.contains("Completed"))
        #expect(labels.contains("Call Params"))
        #expect(labels.contains("Result"))
    }

#if os(iOS)
    @Test("MCP row opens from the compact mobile chat bubble")
    func compactMobileBubbleOpensMCPRow() throws {
        let toolCall = makeMCPToolCall()
        let message = ChatMessage(role: .assistant, blocks: [.toolCall(toolCall)], isStreaming: false)
        let view = ChatMessageBubble(message: message)
        ViewHosting.host(view: view)
        defer { ViewHosting.expel() }

        try view.inspect().find(ViewType.Button.self).tap()

        let detail = MCPToolDetailSheet(toolCall: toolCall)
        let labels = try detail.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        #expect(labels.contains("Call Params"))
        #expect(labels.contains("Result"))
    }
#endif

    private func makeMCPToolCall() -> ToolCall {
        ToolCall(
            id: "mcp-1",
            name: "mcpToolCall",
            input: [
                "query": .string("saved preferences"),
                "limit": .number(10)
            ],
            result: #"{"ok":true,"items":[]}"#,
            isError: false
        )
    }
}
