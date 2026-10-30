import SwiftUI
import WebKit
import RxCodeCore
#if os(iOS)
import UIKit
#endif

/// Renders a tool call's MCP App directly in the chat transcript.
/// Untrusted HTML runs in an opaque-origin sandbox, with no native APIs.
struct MCPAppInlineView: View {
    let toolCall: ToolCall
    let loader: MCPAppLoader
    @State private var resource: MCPAppResource?

    var body: some View {
        Group {
            if let resource {
                MCPAppInlineHost(resource: resource, toolCall: toolCall)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: resource != nil)
        .task(id: toolCall.id) {
            guard resource == nil else { return }
            // Tools without an App, or servers that can't be reached, simply render no App.
            resource = try? await loader(toolCall)
        }
    }
}

private struct MCPAppInlineHost: View {
    let resource: MCPAppResource
    let toolCall: ToolCall
    @State private var bridge = MCPAppBridge()

    var body: some View {
        MCPAppWebView(resource: resource, toolCall: toolCall, bridge: bridge)
            .frame(height: bridge.preferredHeight)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ClaudeTheme.border, lineWidth: 0.5))
            .overlay {
                if bridge.running {
                    ProgressView("Running App action…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.vertical, 4)
            .confirmationDialog("Allow this MCP App tool call?", isPresented: Binding(
                get: { bridge.pending != nil }, set: { if !$0 { bridge.rejectPending() } }
            ), titleVisibility: .visible) {
                Button("Allow") { bridge.approvePending() }
                Button("Cancel", role: .cancel) { bridge.rejectPending() }
            } message: {
                Text(verbatim: bridge.pendingDescription)
            }
    }
}

@Observable @MainActor
final class MCPAppBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var webView: WKWebView?
    var resource: MCPAppResource?
    var toolCall: ToolCall?
    var pending: JSONValue?
    var running = false
    /// Height requested by the App via `ui/notifications/size-changed`, clamped for the transcript.
    var preferredHeight: CGFloat = 360
    private var operation: Task<Void, Never>?
    private var initialized = false
    private var closed = false

    var pendingDescription: String {
        guard let params = pending?["params"], let data = try? JSONEncoder().encode(params) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, message.frameInfo.isMainFrame,
              let data = try? JSONSerialization.data(withJSONObject: message.body),
              let rpc = try? JSONDecoder().decode(JSONValue.self, from: data),
              rpc["jsonrpc"] == .string("2.0"), let method = rpc["method"]?.stringValue else { return }
        if method == "ui/initialize" {
            guard let id = rpc["id"] else { return }
            send(.object(["jsonrpc": .string("2.0"), "id": id, "result": .object([
                "protocolVersion": .string("2026-01-26"),
                "hostInfo": .object(["name": .string("RxCode"), "version": .string("1")]),
                "hostCapabilities": .object(["serverTools": .object([:])]),
                "hostContext": .object([
                    "displayMode": .string("inline"), "availableDisplayModes": .array([.string("inline")]),
                    "platform": .string("desktop"), "locale": .string(Locale.current.identifier),
                    "toolInfo": .object(["tool": resource?.tool ?? .object([:])])
                ])
            ])]))
        } else if method == "ui/notifications/initialized" {
            guard !initialized else { return }
            initialized = true
            notify("ui/notifications/tool-input", .object(["arguments": .object(toolCall?.input ?? [:])]))
            if let text = toolCall?.result {
                let result = text.data(using: .utf8).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                notify("ui/notifications/tool-result", result?.objectValue != nil ? result! : .object([
                    "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                    "isError": .bool(toolCall?.isError ?? false)
                ]))
            }
        } else if method == "ui/notifications/size-changed" {
            if let height = rpc["params"]?["height"]?.numberValue, height.isFinite {
                preferredHeight = min(max(CGFloat(height), 120), 720)
            }
        } else if initialized, method == "tools/call" {
            guard pending == nil, !running else { reject(rpc, code: -32000, message: "Another App action is pending."); return }
            pending = rpc
#if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
#endif
        } else if initialized, method == "tools/list" {
            run(rpc)
        } else if method == "ping" {
            reply(rpc, result: .object([:]))
        } else if rpc["id"] != nil {
            reject(rpc, code: -32601, message: "Unsupported MCP App method.")
        }
    }

    func approvePending() {
        guard let request = pending else { return }
        pending = nil
        run(request)
    }

    func rejectPending() {
        guard let request = pending else { return }
        pending = nil
        reject(request, code: -32000, message: "The user cancelled the App action.")
    }

    private func run(_ request: JSONValue) {
        guard !running, let resource, let method = request["method"]?.stringValue else { return }
        running = true
        operation = Task {
            defer { running = false }
            do {
                let result = try await resource.call(method, request["params"] ?? .object([:]))
                guard !closed else { return }
                reply(request, result: result)
#if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
#endif
            } catch {
                guard !closed else { return }
                reject(request, code: -32000, message: error.localizedDescription)
#if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.error)
#endif
            }
        }
    }

    func close() {
        closed = true
        operation?.cancel()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mcp")
        resource = nil
    }

    private func reply(_ request: JSONValue, result: JSONValue) {
        guard let id = request["id"] else { return }
        send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func reject(_ request: JSONValue, code: Int, message: String) {
        guard let id = request["id"] else { return }
        send(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object([
            "code": .number(Double(code)), "message": .string(message)
        ])]))
    }

    private func notify(_ method: String, _ params: JSONValue) {
        send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    private func send(_ message: JSONValue) {
        guard !closed, let data = try? JSONEncoder().encode(message), let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage(\(json), '*')", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // No top-level escapes, downloads, file access, or external navigation.
        let allowed = navigationAction.request.url?.scheme == "about" && navigationAction.navigationType == .other
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}

struct MCPAppWebView {
    let resource: MCPAppResource
    let toolCall: ToolCall
    let bridge: MCPAppBridge

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(bridge, name: "mcp")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = bridge
        view.uiDelegate = bridge
        bridge.webView = view
        bridge.resource = resource
        bridge.toolCall = toolCall
        let encoded = Data(resource.html.utf8).base64EncodedString()
        view.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body,iframe{margin:0;width:100%;height:100%;border:0;overflow:hidden}</style></head>
        <body><iframe sandbox="allow-scripts" title="MCP App"></iframe><script>
        const frame = document.querySelector('iframe');
        window.addEventListener('message', event => {
            if(event.source === frame.contentWindow && event.data?.jsonrpc === '2.0') {
                window.webkit.messageHandlers.mcp.postMessage(event.data);
            }
        });
        frame.srcdoc = new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0)));
        </script></body></html>
        """, baseURL: nil)
        return view
    }
}

#if os(macOS)
extension MCPAppWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: ()) {
        (nsView.navigationDelegate as? MCPAppBridge)?.close()
    }
}
#else
extension MCPAppWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        (uiView.navigationDelegate as? MCPAppBridge)?.close()
    }
}
#endif
