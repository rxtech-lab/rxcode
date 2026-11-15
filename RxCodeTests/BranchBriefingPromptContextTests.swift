import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class BranchBriefingPromptContextTests: XCTestCase {
    func testBranchBriefingSystemPromptWrapsRecentWorkAsBackgroundContext() {
        let prompt = AppState.branchBriefingSystemPrompt(
            branch: "feature/search",
            briefing: "- Added natural-language thread search.\n- Updated indexing."
        )

        XCTAssertTrue(prompt.contains("# Current branch briefing"))
        XCTAssertTrue(prompt.contains("Latest notes for `feature/search`"))
        XCTAssertTrue(prompt.contains("- Added natural-language thread search."))
        XCTAssertTrue(prompt.contains("possibly stale"))
    }

    func testLongBriefingHasBoundedPromptSize() {
        let prompt = AppState.branchBriefingSystemPrompt(branch: "main", briefing: String(repeating: "x", count: 20_000))
        XCTAssertLessThan(prompt.count, 4_200)
        XCTAssertTrue(prompt.contains("[Briefing shortened]"))
    }

    func testSkillCatalogueKeepsFullInstructionsOutOfPromptButReadableOnDemand() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skill-prompt-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MarketplaceService(baseURL: directory)
        let instructions = "---\nname: example\ndescription: Use for release tasks.\n---\n" + String(repeating: "Full instructions.\n", count: 1_000)
        let record = MarketplacePluginRecord(name: "example", marketplace: "test", marketplaceSource: nil,
                                             instructions: instructions)
        let prompt = try await service.skillPromptContext(records: [record], directory: directory)
        XCTAssertTrue(prompt.contains("example: Use for release tasks."))
        XCTAssertFalse(prompt.contains("Full instructions."))
        XCTAssertLessThan(prompt.count, 500)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8), instructions)
        let repeated = try await service.skillPromptContext(records: [record], directory: directory)
        XCTAssertEqual(repeated, prompt)
    }

    func testBranchBriefingSystemPromptIgnoresBlankBriefings() {
        XCTAssertEqual(
            AppState.branchBriefingSystemPrompt(branch: "main", briefing: " \n\t "),
            ""
        )
    }

    func testPromptWithBackgroundContextPrefixesCodexAndACPContext() {
        let briefingContext = AppState.branchBriefingSystemPrompt(
            branch: "main",
            briefing: "- Recent work updated MCP tool rendering."
        )
        let memoryContext = "# Relevant user memory\n\nAlways write unit tests."

        let prompt = AppState.promptWithBackgroundContext(
            [briefingContext, memoryContext],
            prompt: "Implement it for all clients."
        )

        XCTAssertTrue(prompt.contains("# Current branch briefing"))
        XCTAssertTrue(prompt.contains("- Recent work updated MCP tool rendering."))
        XCTAssertTrue(prompt.contains("# Relevant user memory"))
        XCTAssertTrue(prompt.hasSuffix("User request:\nImplement it for all clients."))
    }

    func testPromptWithBackgroundContextLeavesPromptUntouchedWhenContextIsEmpty() {
        XCTAssertEqual(
            AppState.promptWithBackgroundContext(["", " \n\t "], prompt: "Only the request."),
            "Only the request."
        )
    }

    func testConfiguredPromptsKeepGlobalBeforeProjectAndIgnoreBlankValues() {
        XCTAssertEqual(
            AppState.configuredPromptContext(global: "  Use English.  ", project: "  Follow project conventions.\n"),
            "# Global instructions\n\nUse English.\n\n# Project instructions\n\nFollow project conventions."
        )
        XCTAssertEqual(AppState.configuredPromptContext(global: "  ", project: nil), "")
    }
}
