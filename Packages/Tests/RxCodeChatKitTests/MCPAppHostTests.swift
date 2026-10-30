import Testing
import Foundation
import WebKit
import RxCodeCore
@testable import RxCodeChatKit

@MainActor
@Suite("MCP App native host")
struct MCPAppHostTests {
    @Test func sandboxHandshakeAndUserApprovedToolCall() async throws {
        let calls = CallCounter()
        let resource = MCPAppResource(html: #"""
        <!doctype html><script>
        let input = false, result = false;
        window.addEventListener('message', event => {
            const msg = event.data;
            if (msg.id === 1 && msg.result) {
                parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized'}, '*');
            }
            if (msg.method === 'ui/notifications/tool-input') input = msg.params.arguments.city === 'Tokyo';
            if (msg.method === 'ui/notifications/tool-result') result = msg.params.structuredContent.ready === true;
            if (input && result) {
                input = result = false;
                parent.postMessage({jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'refresh',arguments:{}}}, '*');
            }
        });
        parent.postMessage({jsonrpc:'2.0',id:1,method:'ui/initialize',params:{protocolVersion:'2026-01-26',appCapabilities:{},appInfo:{name:'fixture',version:'1'}}}, '*');
        </script>
        """#, tool: .object(["name": .string("dashboard")])) { _, _ in
            await calls.increment()
            return .object(["content": .array([])])
        }
        let toolCall = ToolCall(id: "original", name: "mcp__fixture__dashboard", input: ["city": .string("Tokyo")],
            result: #"{"content":[],"structuredContent":{"ready":true}}"#)
        let bridge = MCPAppBridge()
        let webView = MCPAppWebView(resource: resource, toolCall: toolCall, bridge: bridge).makeWebView()
        defer { bridge.close(); webView.stopLoading() }
        let deadline = Date().addingTimeInterval(10)
        while bridge.pending == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(bridge.pending?["params"]?["name"] == .string("refresh"))
        #expect(await calls.value == 0, "App tools require user approval")
        bridge.approvePending()
        while bridge.running && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await calls.value == 1)
        #expect(bridge.pending == nil)
    }

    @Test func inlineAppResizesWithinTranscriptBounds() async throws {
        let resource = MCPAppResource(html: #"""
        <!doctype html><script>
        parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/size-changed',params:{height:5000}}, '*');
        </script>
        """#, tool: .object(["name": .string("dashboard")])) { _, _ in .object([:]) }
        let toolCall = ToolCall(id: "inline", name: "mcp__fixture__dashboard", input: [:], result: "{}")
        let bridge = MCPAppBridge()
        let webView = MCPAppWebView(resource: resource, toolCall: toolCall, bridge: bridge).makeWebView()
        defer { bridge.close(); webView.stopLoading() }
        let deadline = Date().addingTimeInterval(10)
        while bridge.preferredHeight == 360 && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(bridge.preferredHeight == 720, "App height is clamped so it can't take over the chat")
    }

    private actor CallCounter {
        var value = 0
        func increment() { value += 1 }
    }
}
