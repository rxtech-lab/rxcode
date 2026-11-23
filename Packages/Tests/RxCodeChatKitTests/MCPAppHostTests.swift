import Testing
import Foundation
import WebKit
import SwiftUI
import ViewInspector
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

extension MCPAppHostTests {
    @Test func malformedResourceLeavesOriginalResultAvailable() async throws {
        let call = ToolCall(id: "fallback", name: "mcp__fixture__forecast", input: [:], result: "Original forecast")
        let window = WindowState()
        var loadedID: String?
        window.mcpAppLoader = { tool in
            loadedID = tool.id
            let malformed = try MCPJSONUIResource(data: Data("{}".utf8))
            return MCPAppResource(jsonUI: malformed, tool: [:]) { _ in .null }
        }
        let row = ToolResultView(toolCall: call).environment(window)
        ViewHosting.host(view: row)
        defer { ViewHosting.expel() }
        try await waitUntil { loadedID == call.id }
        try row.inspect().find(ViewType.Button.self).tap()
        let texts = try ToolCallDetailSheet(toolCall: call).inspect().findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
        #expect(texts.contains { $0.contains("Original forecast") })
    }

    @Test func boundSubmitUsesEditedValuesAndPreservesThePendingSnapshot() async throws {
        let probe = SubmissionProbe()
        let document = try makeNativeDocument()
        let host = MCPJSONUIInlineHost(document: document, submit: probe.submit)
        let state = host.interaction
        state.values["city"] = "Paris"

        // Reevaluate the native host and renderer while the form has an edit.
        for _ in 0..<2 {
            let renderer = try host.inspect().find(JSONUIRenderer.self).actualView()
            let rendered = try renderer.inspect().find(JSONUIInteractiveHost<AnyView>.self).actualView()
            #expect(rendered.interaction === state)
            #expect(rendered.interaction.values["city"] == "Paris")
        }
        #expect(MCPJSONUIInlineHost(document: document, submit: probe.submit).interaction.values["city"] == "Tokyo")
        let button = JSONUIControl(id: "save", element: try #require(document.spec.elements["save"]), interaction: state)
        try button.inspect().find(ViewType.Button.self).tap()
        #expect(state.submissions["save"] == .pending)
        state.values["city"] = "London"
        state.perform(["type": "submit"], elementID: "save")
        // A different action in the same form can be pending independently.
        state.perform(["type": "submit"], elementID: "check")
        #expect(state.submissions["check"] == .pending)
        try await waitUntil { await probe.count == 2 }
        let calls = await probe.calls
        #expect(calls.first { $0.actionID == "save" }?.arguments == ["place": "Paris"])
        #expect(calls.first { $0.actionID == "check" }?.arguments == ["place": "London"])
        await probe.finish("save", with: .success(["content": [["type": "text", "text": "Saved Paris"]]]))
        await probe.finish("check", with: .failure(Denied()))
        try await waitUntil { state.submissions["save"] != .pending && state.submissions["check"] != .pending }
        #expect(state.submissions["save"] == .success("Saved Paris"))
        #expect(state.submissions["check"] == .failure("Approval declined."))

        // A completed or denied action can be submitted again with the current draft.
        state.perform(["type": "submit"], elementID: "check")
        try await waitUntil { await probe.count == 3 }
        await probe.finish("check", with: .success(["isError": true, "content": [["type": "text", "text": "Tool unavailable"]]]))
        try await waitUntil { state.submissions["check"] != .pending }
        #expect(state.submissions["check"] == .failure("Tool unavailable"))
    }

    @Test func presentationRootStaysInlineAndRequiredValuesBlockDispatch() throws {
        let document = try makeNativeDocument(rootType: "Dialog")
        let host = MCPJSONUIInlineHost(document: document) { _ in
            Issue.record("An invalid form reached the host")
            return .null
        }
        let state = host.interaction
        #expect(state.presented == nil)
        #expect(try host.inspect().find(text: "Weather").string() == "Weather")
        state.values["city"] = "  "
        state.perform(["type": "submit"], elementID: "save")
        #expect(state.submissions.isEmpty)
        #expect(state.notice?.contains("required") == true)
    }

    private func makeNativeDocument(rootType: String = "Form") throws -> MCPJSONUIResource {
        let submit: JSONValue = ["type": "Button", "props": ["action": ["type": "submit"]]]
        let binding: JSONValue = ["tool": "forecast", "arguments": ["place": "city"]]
        let document: JSONValue = [
            "presentation": "dialog",
            "root": "weather",
            "elements": [
                "weather": ["type": .string(rootType), "props": ["title": "Weather"], "children": ["city", "save", "check"]],
                "city": ["type": "TextField", "props": ["required": true, "value": "Tokyo"]],
                "save": submit, "check": submit
            ],
            "bindings": ["save": binding, "check": binding]
        ]
        return try MCPJSONUIResource(data: JSONEncoder().encode(document))
    }

    private struct Denied: LocalizedError {
        var errorDescription: String? { "Approval declined." }
    }

    private struct Timeout: Error {}
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private actor SubmissionProbe {
        private(set) var calls: [MCPJSONUIActionContext] = []
        var count: Int { calls.count }
        private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]

        func submit(_ context: MCPJSONUIActionContext) async throws -> JSONValue {
            calls.append(context)
            return try await withCheckedThrowingContinuation { pending[context.actionID] = $0 }
        }

        func finish(_ id: String, with result: Result<JSONValue, Error>) {
            pending.removeValue(forKey: id)?.resume(with: result)
        }
    }
}
