import Synchronization
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

@MainActor
private final class MCPFormFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let process = Process()
    let project = "/fixture/project"
    let thread = "mcp-form-thread"
    let call = ToolCall(id: "weather-call", name: "mcp__weather__dashboard")
    let app = AppState(startBackgroundServices: false)
    let oauth: MCPOAuthService
    let spec: MCPServerSpec
    let example: JSONValue

    init() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("provider.py")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
        let exampleURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/fixtures/mcp-json-ui-v1.json")
        let exampleData = try Data(contentsOf: exampleURL)
        example = try JSONValue(jsonData: exampleData)
        try exampleData.write(to: root.appendingPathComponent("example.json"))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        try process.run()
        let portURL = root.appendingPathComponent("port")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: portURL.path) && process.isRunning {
            try await Task.sleep(for: .milliseconds(25))
        }
        let port = try String(contentsOf: portURL, encoding: .utf8)
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp"))
        let credential = MCPOAuthService.Credential(accessToken: "first", refreshToken: "rotate-me", expiresAt: .distantFuture,
            clientID: "native-fixture", tokenEndpoint: endpoint.deletingLastPathComponent().appendingPathComponent("token"),
            resource: endpoint.absoluteString)
        let stored = Mutex<MCPOAuthService.Credential?>(credential)
        oauth = MCPOAuthService(storage: .init(read: { resource in
            stored.withLock { $0?.resource == resource ? $0 : nil }
        }, write: { newValue in stored.withLock { $0 = newValue } }, delete: { _ in stored.withLock { $0 = nil } }))
        spec = MCPServerSpec(name: "weather", transport: .http, url: endpoint.absoluteString,
                             headers: [.init(key: "X-Project-Header", value: "weather")])
        try JSONEncoder().encode(MCPConfiguration()).write(to: root.appendingPathComponent("mcp.json"))
        app.mcp = MCPService(baseURL: root, claudeService: app.claude, oauth: oauth)
        try await app.mcp.add(spec: spec, scope: .project, projectPath: project)
    }

    func finish() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }

    func mode(_ value: String) throws {
        try value.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
    }

    func events() throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func resource() async throws -> MCPAppResource {
        let loaded = try await app.loadMCPApp(for: call, projectPath: project, sessionKey: thread)
        return try XCTUnwrap(loaded)
    }

    func action(_ resource: MCPAppResource, city: JSONValue = "Tokyo") throws -> MCPJSONUIActionContext {
        guard case .jsonUI(let document) = resource.content else { throw FixtureError.expectedJSON }
        return try XCTUnwrap(document.actionContext(for: "refresh", values: ["place": city, "metric": .bool(true)]))
    }

    func pending() async throws -> AgentConfirmation {
        for _ in 0..<200 {
            if let prompt = app.agentConfirmations(forSession: thread).first { return prompt }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.missingPrompt
    }

    private enum FixtureError: Error { case expectedJSON, missingPrompt }

    /// The server accepts the original credential for reads. Only tools/call requires rotation.
    private static let server = #"""
    import base64, json, time
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from pathlib import Path
    from urllib.parse import parse_qs

    fixture = json.loads(Path('example.json').read_text())
    def event(name):
        with Path('events').open('a') as f:
            print(name, file=f)

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def reply(self, code, data=b'', mime='application/json'):
            self.send_response(code)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Mcp-Session-Id', 'weather-session')
            self.end_headers()
            self.wfile.write(data)
        def do_POST(self):
            data = self.rfile.read(int(self.headers['Content-Length']))
            mode = Path('mode').read_text() if Path('mode').exists() else 'dual'
            if self.path == '/token':
                form = parse_qs(data.decode())
                assert form == {'grant_type':['refresh_token'], 'refresh_token':['rotate-me'], 'client_id':['native-fixture'],
                                'resource':['http://127.0.0.1:%d/mcp' % self.server.server_port]}
                event('refresh')
                if mode == 'pause-refresh':
                    for _ in range(200):
                        if Path('mode').read_text() != 'pause-refresh': break
                        time.sleep(0.025)
                return self.reply(200, b'{"access_token":"renewed","refresh_token":"rotated","token_type":"Bearer","expires_in":3600}')
            assert self.path == '/mcp' and self.headers['X-Project-Header'] == 'weather'
            token = self.headers['Authorization']
            assert token in ['Bearer first', 'Bearer renewed']
            rpc = json.loads(data)
            method = rpc['method']
            event(method)
            if method != 'initialize': assert self.headers['Mcp-Session-Id'] == 'weather-session'
            if method == 'notifications/initialized': return self.reply(202)
            if method == 'initialize':
                advertised = rpc['params']['capabilities']['extensions']['io.modelcontextprotocol/ui']['mimeTypes']
                assert set(advertised) == {fixture['mimeType'], 'text/html;profile=mcp-app'}
                result = {'protocolVersion':'2025-11-25','capabilities':{},'serverInfo':{'name':'weather','version':'1'}}
            elif method == 'tools/list':
                tools = [
                    {'name':'dashboard','inputSchema':{'type':'object'},'_meta':{'ui':{'resourceUri':fixture['uri']}}},
                    {'name':'get_forecast','inputSchema':{'type':'object','properties':{'city':{'type':'string'},'metricUnits':{'type':'boolean'}},
                         'required':['city','metricUnits'],'additionalProperties':False},
                     '_meta':{'ui':{'visibility':['model' if mode == 'hidden' else 'app']}}}
                ]
                if mode == 'changed-schema':
                    tools[1]['inputSchema']['properties']['city']['maxLength'] = 100
                result = {'tools':tools}
            elif method == 'resources/read':
                assert rpc['params']['uri'] == fixture['uri']
                uri = 'ui://different/app' if mode == 'mismatch' else fixture['uri']
                doc = json.dumps(fixture['document'])
                if mode == 'malformed': doc = '{'
                if mode == 'oversize': doc += ' ' * 512000
                native = {'uri':uri,'mimeType':fixture['mimeType'],'blob':base64.b64encode(doc.encode()).decode()}
                html = {'uri':uri,'mimeType':'text/html;profile=mcp-app','text':'<p>weather</p>'}
                result = {'contents':[html,native] if mode == 'dual' else [native]}
            elif method == 'tools/call':
                assert rpc['params'] == fixture['expectedCall']
                if token == 'Bearer first':
                    self.server.rejected = data
                    return self.reply(401)
                assert data == self.server.rejected
                event('accepted')
                result = fixture['response']
            else:
                return self.reply(404)
            response = json.dumps({'jsonrpc':'2.0','result':result,'id':rpc['id']}).encode()
            if method == 'tools/call': return self.reply(200, b'data: '+response+b'\n\n', 'text/event-stream')
            self.reply(200, response)

    server = HTTPServer(('127.0.0.1', 0), Provider)
    Path('port').write_text(str(server.server_port))
    server.serve_forever()
    """#
}

extension MCPAppConnectionTests {
    func testApprovedNativeSubmissionRefreshesOAuthOnceAndReplaysExactCall() async throws {
        let fixture = try await MCPFormFixture()
        defer { fixture.finish() }
        let resource = try await fixture.resource()
        let submit = try XCTUnwrap(resource.submit)
        let action = try fixture.action(resource)
        let task = Task { try await submit(action) }
        defer { task.cancel() }
        let prompt = try await fixture.pending()
        XCTAssertEqual(prompt.sessionKey, fixture.thread)
        let displayed = try JSONValue(jsonData: Data(try XCTUnwrap(prompt.request.message).utf8))
        XCTAssertEqual(displayed["server"], "weather")
        XCTAssertEqual(displayed["project"], .string(fixture.project))
        XCTAssertEqual(displayed["toolCallID"], .string(fixture.call.id))
        XCTAssertEqual(displayed["tool"], fixture.example["expectedCall"]?["name"])
        XCTAssertEqual(displayed["arguments"], fixture.example["expectedCall"]?["arguments"])
        do {
            _ = try await submit(action)
            XCTFail("A duplicate submit reached approval.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("already pending")) }
        XCTAssertFalse(try fixture.events().contains("tools/call"))
        fixture.app.resolveAgentConfirmation(id: prompt.id, confirmed: true)
        let result = try await task.value
        XCTAssertEqual(result, fixture.example["response"])
        XCTAssertEqual(try fixture.events().suffix(4), ["tools/call", "refresh", "tools/call", "accepted"])
    }

    func testDeniedAndRevokedFormsNeverDispatch() async throws {
        let fixture = try await MCPFormFixture()
        defer { fixture.finish() }
        try fixture.mode("native")
        let resource = try await fixture.resource()
        let submit = try XCTUnwrap(resource.submit)
        let action = try fixture.action(resource)
        for change in ["deny", "hidden", "changed-schema", "disabled", "replaced", "signed-out"] {
            let task = Task { try await submit(action) }
            defer { task.cancel() }
            let prompt = try await fixture.pending()
            switch change {
            case "hidden", "changed-schema": try fixture.mode(change)
            case "disabled": try await fixture.app.mcp.setProjectOverride(name: "weather", projectPath: fixture.project, override: .disabled)
            case "replaced":
                var replacement = fixture.spec
                replacement.url += "/changed"
                try await fixture.app.mcp.add(spec: replacement, scope: .project, projectPath: fixture.project)
            case "signed-out": try await fixture.oauth.signOut(resource: fixture.spec.url)
            default: break
            }
            fixture.app.resolveAgentConfirmation(id: prompt.id, confirmed: change != "deny")
            do { _ = try await task.value; XCTFail("The \(change) submission reached the server.") } catch {
                XCTAssertFalse(error is CancellationError)
            }
            try fixture.mode("native")
            if change == "disabled" || change == "replaced" {
                try await fixture.app.mcp.add(spec: fixture.spec, scope: .project, projectPath: fixture.project)
            }
        }
        XCTAssertFalse(try fixture.events().contains("tools/call"))
    }

    func testProjectRevokedDuringTokenRefreshPreventsReplay() async throws {
        let fixture = try await MCPFormFixture()
        defer { fixture.finish() }
        try fixture.mode("pause-refresh")
        let resource = try await fixture.resource()
        let submit = try XCTUnwrap(resource.submit)
        let action = try fixture.action(resource)
        let task = Task { try await submit(action) }
        defer { task.cancel() }
        let prompt = try await fixture.pending()
        fixture.app.resolveAgentConfirmation(id: prompt.id, confirmed: true)
        for _ in 0..<200 {
            if try fixture.events().contains("refresh") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(try fixture.events().contains("refresh"))
        try await fixture.app.mcp.setProjectOverride(name: "weather", projectPath: fixture.project, override: .disabled)
        try fixture.mode("native")
        do { _ = try await task.value; XCTFail("Revoked approval reached the replay.") } catch {
            XCTAssertTrue(error.localizedDescription.contains("unavailable in this project"))
        }
        XCTAssertEqual(try fixture.events().filter { $0 == "tools/call" }.count, 1)
        XCTAssertFalse(try fixture.events().contains("accepted"))
    }

    func testNativeResourceSelectionAndValidationBeforeApproval() async throws {
        let fixture = try await MCPFormFixture()
        defer { fixture.finish() }
        let unavailable = try await fixture.app.loadMCPApp(for: fixture.call, projectPath: "/another/project", sessionKey: fixture.thread)
        XCTAssertNil(unavailable)
        for mode in ["mismatch", "malformed", "oversize"] {
            try fixture.mode(mode)
            do { _ = try await fixture.resource(); XCTFail("Invalid \(mode) resource loaded.") } catch {}
        }
        try fixture.mode("native")
        let resource = try await fixture.resource()
        let submit = try XCTUnwrap(resource.submit)
        do {
            _ = try await submit(fixture.action(resource, city: .number(5)))
            XCTFail("Invalid arguments reached approval.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("input schema")) }
        XCTAssertTrue(fixture.app.agentConfirmations(forSession: fixture.thread).isEmpty)
        XCTAssertFalse(try fixture.events().contains("tools/call"))
    }

    func testQualifiedServerNameTakesPrecedenceOverToolInputAndEnablement() {
        let short = MCPServerRecord(name: "weather", transport: .stdio)
        let long = MCPServerRecord(name: "weather__daily", transport: .stdio, isGloballyEnabled: false)
        let input: [String: JSONValue] = ["server": "weather", "tool": "other"]
        let records = [short, long]
        let direct = ToolCall(id: "call", name: "mcp__weather__daily__dashboard", input: input)
        let resolved = AppState.mcpAppOrigin(for: direct, records: records)
        XCTAssertEqual(resolved?.0.name, long.name)
        XCTAssertEqual(resolved?.1, "dashboard")
        let unknown = ToolCall(id: "other", name: "mcp__unknown__dashboard", input: input)
        XCTAssertNil(AppState.mcpAppOrigin(for: unknown, records: records))
        let legacy = ToolCall(id: "legacy", name: "mcpToolCall", input: input)
        XCTAssertEqual(AppState.mcpAppOrigin(for: legacy, records: records)?.0.name, short.name)
    }
}
