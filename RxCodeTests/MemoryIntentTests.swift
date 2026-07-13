import XCTest
@testable import RxCode

@MainActor
final class MemoryIntentTests: XCTestCase {
    func testMemoryExtractionPromptUsesAllUserMessagesAsSource() {
        let prompt = OpenAISummarizationService.memoryExtractionPrompt(
            existingMemories: [],
            userMessages: [
                "For future RxCode changes, always run the focused memory tests.",
                "Now implement the feature."
            ]
        )

        XCTAssertTrue(prompt.contains("### User message 1\nFor future RxCode changes, always run the focused memory tests."))
        XCTAssertTrue(prompt.contains("### User message 2\nNow implement the feature."))
    }

    func testMemoryExtractionPromptDoesNotUseAssistantResponseAsSource() {
        let prompt = OpenAISummarizationService.memoryExtractionPrompt(
            existingMemories: [],
            userMessages: ["Remember to keep the MCP memory tool unchanged."]
        )

        XCTAssertTrue(prompt.contains("The user messages below are the only source for new memory."))
        XCTAssertFalse(prompt.contains("Final assistant response:"))
        XCTAssertFalse(prompt.contains("Latest user message:"))
    }

    func testMemoryExtractionPromptRejectsNoisyConversationArtifacts() {
        let prompt = OpenAISummarizationService.memoryExtractionPrompt(
            existingMemories: [],
            userMessages: ["Hi"]
        )

        XCTAssertTrue(prompt.contains("Do not save greetings"))
        XCTAssertTrue(prompt.contains("Updated it."))
        XCTAssertTrue(prompt.contains("Implemented debug timing logs"))
        XCTAssertTrue(prompt.contains("Build succeeded"))
        XCTAssertTrue(prompt.contains("What changed:"))
    }

    func testParsesMemoryOperationsFromFencedJSON() {
        let raw = """
        ```json
        [
          {"action":"add","content":"Always use vector search for memory injection.","kind":"preference","scope":"project"},
          {"action":"delete","id":"old-id"}
        ]
        ```
        """

        let operations = AppState.parseMemoryOperations(raw)

        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0].action, "add")
        XCTAssertEqual(operations[0].content, "Always use vector search for memory injection.")
        XCTAssertEqual(operations[0].kind, "preference")
        XCTAssertEqual(operations[0].scope, "project")
        XCTAssertEqual(operations[1].action, "delete")
        XCTAssertEqual(operations[1].id, "old-id")
    }

    func testMemoryExtractionPromptIncludesExistingMemoriesForUpdateOrDelete() {
        let prompt = OpenAISummarizationService.memoryExtractionPrompt(
            existingMemories: [(id: "memory-1", content: "Always run make lint.")],
            userMessages: ["Do not run make lint by default anymore."]
        )

        XCTAssertTrue(prompt.contains("- id: memory-1\n  content: Always run make lint."))
        XCTAssertTrue(prompt.contains("If an existing memory should be refined, return an update operation with its id."))
    }

    func testMemoryMCPConfigurationUsesLoopbackHTTPURL() throws {
        let raw = try XCTUnwrap(
            IDEMCPServer.memoryAPIConfiguration(port: IDEMCPServer.memoryAPIDefaultPort)
        )
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let servers = try XCTUnwrap(root["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["rxcode"] as? [String: Any])

        XCTAssertEqual(
            server["url"] as? String,
            "http://127.0.0.1:\(IDEMCPServer.memoryAPIDefaultPort)/mcp"
        )
        XCTAssertNil(server["command"])
        XCTAssertNil(server["args"])
    }

    func testMemoryMCPEndpointRejectsReservedPort() {
        XCTAssertEqual(
            IDEMCPServer.memoryAPIEndpoint(port: IDEMCPServer.memoryAPIDefaultPort)?.absoluteString,
            "http://127.0.0.1:19846/mcp"
        )
        XCTAssertNil(IDEMCPServer.memoryAPIEndpoint(port: 19847))
    }

    func testMemoryMCPPortValidationReservesChatListenerRange() {
        XCTAssertTrue(IDEMCPServer.isValidMemoryAPIPort(IDEMCPServer.memoryAPIDefaultPort))
        XCTAssertFalse(IDEMCPServer.isValidMemoryAPIPort(19847))
        XCTAssertFalse(IDEMCPServer.isValidMemoryAPIPort(19946))
        XCTAssertFalse(IDEMCPServer.isValidMemoryAPIPort(1023))
    }

    func testMCPServerToolSelectionRoundTripsInStableOrder() {
        let selected: Set<MCPServerTool> = [.memoryUpdate, .memorySearch]

        let storedValue = IDEMCPServer.storedValue(for: selected)

        XCTAssertEqual(storedValue, "memory_search,memory_update")
        XCTAssertEqual(IDEMCPServer.exposedTools(from: storedValue), selected)
    }

    func testMCPServerDefaultsExposeMemorySearchWithoutMemoryGet() {
        let exposedTools = IDEMCPServer.exposedTools(from: nil)

        XCTAssertEqual(exposedTools, Set(MCPServerTool.allCases))
        XCTAssertTrue(exposedTools.contains(.memorySearch))
        XCTAssertFalse(IDEMCPServer.defaultExposedToolsValue.contains("memory_get"))
    }
}
