import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class MCPAppConnectionTests: XCTestCase {
    func testLoadsResourceWithoutExecutingToolAndScopesAppCalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("app_server.py")
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        let detail = MCPServerDetail(name: "fixture", scope: .user, transport: .stdio, url: nil,
            command: "/usr/bin/python3", args: [script.path], env: [:])
        let connection = MCPAppConnection(detail: detail)
        let loaded = try await connection.load(toolName: "dashboard")
        let app = try XCTUnwrap(loaded)
        XCTAssertTrue(app.html.contains("calls=0"), "Opening the App must not rerun the original tool")
        XCTAssertTrue(app.html.contains("connect-src 'none'"))
        let listed = try await app.call("tools/list", .object([:]))
        let listData = try JSONEncoder().encode(listed)
        let listObject = try XCTUnwrap(JSONSerialization.jsonObject(with: listData) as? [String: Any])
        let visibleTools = try XCTUnwrap(listObject["tools"] as? [[String: Any]])
        XCTAssertEqual(visibleTools.count, 2)
        XCTAssertEqual(visibleTools[0]["name"] as? String, "dashboard")
        XCTAssertEqual(visibleTools[1]["name"] as? String, "refresh")
        let result = try await app.call("tools/call", .object(["name": .string("refresh"), "arguments": .object([:])]))
        XCTAssertEqual(result["structuredContent"]?["calls"], .number(1))
        for name in ["model_only", "other_server_tool"] {
            do {
                _ = try await app.call("tools/call", .object(["name": .string(name)]))
                XCTFail("An App must not call a hidden or unknown tool")
            } catch { XCTAssertTrue(error.localizedDescription.contains("cannot call")) }
        }
    }

    private var fixture: String {
        #"""
        import sys, json
        calls = 0
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request:
                continue
            method = request['method']
            if method == 'initialize':
                result = {'protocolVersion': '2025-11-25', 'capabilities': {}, 'serverInfo': {'name': 'fixture', 'version': '1'}}
            elif method == 'tools/list':
                result = {'tools': [
                    {'name': 'dashboard', 'inputSchema': {'type':'object'}, '_meta': {'ui': {'resourceUri':'ui://fixture/app'}}},
                    {'name': 'refresh', 'inputSchema': {'type':'object'}, '_meta': {'ui': {'visibility':['app']}}},
                    {'name': 'model_only', 'inputSchema': {'type':'object'}, '_meta': {'ui': {'visibility':['model']}}}
                ]}
            elif method == 'resources/read':
                result = {'contents': [{'uri':'ui://fixture/app', 'mimeType':'text/html;profile=mcp-app', 'text': '<html><body>calls=%d</body></html>' % calls}]}
            elif method == 'tools/call':
                calls += 1
                result = {'content': [], 'structuredContent': {'calls': calls}}
            else:
                result = {}
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}), flush=True)
        """#
    }
}
