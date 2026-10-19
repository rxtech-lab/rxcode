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
