import Testing
import Foundation
@testable import RxCodeCore

@Suite("MCP Apps metadata and sandbox policy")
struct MCPAppTests {
    @Test func supportsModernAndLegacyResourceMetadata() {
        let modern: JSONValue = .object(["_meta": .object(["ui": .object(["resourceUri": .string("ui://app/view")])])])
        let legacy: JSONValue = .object(["_meta": .object(["ui/resourceUri": .string("ui://app/legacy")])])
        #expect(MCPAppResource.resourceURI(in: modern) == "ui://app/view")
        #expect(MCPAppResource.resourceURI(in: legacy) == "ui://app/legacy")
        #expect(MCPAppResource.resourceURI(in: .object(["_meta": .object([
            "ui/resourceUri": .string("https://untrusted.example/app")
        ])])) == nil)
    }

    @Test func preservesClaudeStructuredResultForApps() throws {
        let json = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"call-1","content":"fallback"}]},"tool_use_result":{"content":[],"structuredContent":{"count":3},"_meta":{"private":"app-data"}}}"#
        let message = try JSONDecoder().decode(UserMessage.self, from: Data(json.utf8))
        #expect(message.toolUseId == "call-1")
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(message.content.utf8))
        #expect(result["structuredContent"]?["count"] == .number(3))
        #expect(result["_meta"]?["private"] == .string("app-data"))
    }

    @Test func honorsAppOnlyAndModelOnlyVisibility() {
        func tool(_ visibility: [String]) -> JSONValue {
            .object(["_meta": .object(["ui": .object(["visibility": .array(visibility.map(JSONValue.string))])])])
        }
        #expect(MCPAppResource.permitsAppCall(tool(["app"])))
        #expect(!MCPAppResource.permitsAppCall(tool(["model"])))
        #expect(!MCPAppResource.permitsAppCall(["_meta": ["ui": ["visibility": "model"]]]))
        #expect(MCPAppResource.permitsAppCall(.object([:])))
    }

    @Test func deniesUndeclaredNetworkAndFrames() {
        let policy = MCPAppResource.contentSecurityPolicy(meta: nil)
        #expect(policy.contains("connect-src 'none'"))
        #expect(policy.contains("frame-src 'none'"))
        #expect(policy.contains("object-src 'none'"))
        #expect(policy.contains("form-action 'none'"))
    }

    @Test func onlyAllowsDeclaredHTTPSOriginsWithoutPolicyInjection() {
        let policy = MCPAppResource.contentSecurityPolicy(meta: .object(["csp": .object([
            "connectDomains": .array([
                .string("https://api.example.com:8443"), .string("https://example.com;script-src *"),
                .string("https://example.com/path"), .string("http://insecure.example"),
                .string("https://example.com%3Bscript-src%20*"),
                .string("https://user:secret@example.com"), .string("https://example.com/?query=1")
            ]),
            "resourceDomains": .array([.string("https://cdn.example.com")])
        ])]))
        #expect(policy.contains("connect-src https://api.example.com:8443;"))
        #expect(policy.contains("https://cdn.example.com"))
        #expect(!policy.contains("secret"))
        #expect(!policy.contains("script-src *"))
        #expect(!policy.contains("http://"))
        #expect(!policy.contains("/path"))
    }
}

extension MCPAppTests {
    @Test func fixtureProducesOnlyItsDeclaredArguments() async throws {
        let fixtureURL = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../docs/fixtures/mcp-json-ui-v1.json").standardizedFileURL
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtureURL))
        #expect(fixture["mimeType"]?.stringValue == MCPJSONUIResource.mimeType)
        let document = try MCPJSONUIResource(data: JSONEncoder().encode(try #require(fixture["document"])))
        var values = document.spec.initialValues
        values["unmapped"] = "private draft"
        let context = try #require(try document.actionContext(for: "refresh", values: values))
        #expect(context.actionID == "refresh")
        #expect(context.toolName == fixture["expectedCall"]?["name"]?.stringValue)
        #expect(context.arguments == fixture["expectedCall"]?["arguments"]?.objectValue)
        let resource = MCPAppResource(jsonUI: document, tool: ["name": "forecast"]) { _ in
            try #require(fixture["response"])
        }
        guard case .jsonUI = resource.content else { Issue.record("Expected native UI"); return }
        let submit = try #require(resource.submit)
        #expect(try await submit(context) == fixture["response"])
        #expect(try document.actionContext(for: "unbound", values: values) == nil)
        #expect(throws: MCPJSONUIResource.InvalidDocument.self) {
            try document.actionContext(for: "refresh", values: [:])
        }
    }

    @Test func graphAndDocumentLimitsApplyBeforeRendering() throws {
        func check(_ elements: [String: JSONUIElement]) throws {
            let data = try JSONEncoder().encode(JSONUISpec(root: "root", elements: elements))
            #expect(throws: MCPJSONUIResource.InvalidDocument.self) { try MCPJSONUIResource(data: data) }
        }
        #expect(throws: MCPJSONUIResource.InvalidDocument.self) {
            try MCPJSONUIResource(data: Data(repeating: 32, count: MCPJSONUIResource.maxBytes + 1))
        }
        #expect(throws: MCPJSONUIResource.InvalidDocument.self) {
            try MCPJSONUIResource(data: Data(String(repeating: "[", count: 65).utf8))
        }
        #expect(throws: DecodingError.self) { try MCPJSONUIResource(data: Data("{".utf8)) }

        try check(["root": .init(type: "Stack", children: ["a", "b"]),
                   "a": .init(type: "Card", children: ["shared"]), "b": .init(type: "Card", children: ["shared"]),
                   "shared": .init(type: "Text")])
        try check(["root": .init(type: "Text"), "a": .init(type: "Sheet", children: ["b"]), "b": .init(type: "Stack", children: ["a"])])
        try check(["root": .init(type: "Form", children: ["missing"])])
        try check(["root": .init(type: "Unknown")])
        try check(["root": .init(type: "Picker", props: ["options": []])])
        let manyElements = Dictionary(uniqueKeysWithValues: (0...JSONUICatalog.maxElements).map { ("e\($0)", JSONUIElement(type: "Text")) })
        try check(manyElements)
        var deep: [String: JSONUIElement] = ["root": .init(type: "Sheet", children: ["0"])]
        for i in 0..<JSONUICatalog.maxDepth {
            deep[String(i)] = .init(type: "Stack", children: i + 1 < JSONUICatalog.maxDepth ? [String(i + 1)] : [])
        }
        try check(deep)
        let entries = JSONValue.array(Array(repeating: .object([:]), count: 100))
        try check(["root": .init(type: "Table", props: ["columns": entries, "rows": entries])])
    }

    @Test func bindingsValidateSubmitControlsAndFormScope() throws {
        let elements: JSONValue = [
            "one": ["type": "Form", "children": ["field", "save"]],
            "field": ["type": "TextField", "props": ["name": "firstName"]],
            "save": ["type": "Button", "props": ["action": ["type": "submit"]]],
            "two": ["type": "Form", "children": ["other"]],
            "other": ["type": "TextField"]
        ]
        let valid: JSONValue = ["tool": "save", "arguments": ["name": "firstName"]]
        for bindings: JSONValue in [
            ["missing": valid], ["field": valid],
            ["save": ["tool": "save", "arguments": ["name": "field"]]],
            ["save": ["tool": "save", "arguments": ["name": "other"]]],
            ["save": ["tool": "mcp__other__save", "arguments": [:]]],
            ["save": ["server": "other", "tool": "save", "arguments": [:]]]
        ] {
            let json: JSONValue = ["root": "one", "elements": elements, "bindings": bindings]
            #expect(throws: MCPJSONUIResource.InvalidDocument.self) { try MCPJSONUIResource(data: JSONEncoder().encode(json)) }
        }
        let json: JSONValue = ["root": "one", "elements": elements, "bindings": ["save": valid]]
        let document = try MCPJSONUIResource(data: JSONEncoder().encode(json))
        #expect(try document.actionContext(for: "save", values: ["firstName": "Ada"])?.arguments == ["name": "Ada"])
    }

    @Test func outOfRangeNumberFormatsRemainDisplayable() {
        for format in ["duration", "bytes"] {
            #expect(JSONUIFormat.text(.number(1e100), format: format) == (1e100).formatted())
        }
    }
}
