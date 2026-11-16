import Testing
@testable import RxCodeCore

struct MediaToolTests {
    @Test func mediaToolsReachEveryAgentProvider() {
        for capabilities in [CapabilitySet(), AgentProvider.claudeCode.staticCapabilities,
                             AgentProvider.codex.staticCapabilities, AgentProvider.acp.staticCapabilities,
                             AgentProvider.localAgent.staticCapabilities] {
            let names = Set(IDEToolRegistry.tools(for: capabilities).map(\.name))
            #expect(names.isSuperset(of: ["ide__media_models", "ide__generate_media", "ide__pet_draft"]))
        }
    }

    @Test func onlyImageRequestsUseTheImagePreview() {
        for name in ["ide__generate_media", "mcp__rxcode-ide__ide__generate_media"] {
            #expect(ToolCall(id: "i", name: name, input: ["kind": .string("image")]).isImageGeneration)
            #expect(!ToolCall(id: "v", name: name, input: ["kind": .string("video")]).isImageGeneration)
            #expect(!ToolCall(id: "a", name: name, input: ["kind": .string("audio")]).isImageGeneration)
        }
        #expect(ToolCall(id: "native", name: "imageGeneration").isImageGeneration)
        #expect(!ToolCall(id: "other", name: "imageSearch").isImageGeneration)
    }
}
