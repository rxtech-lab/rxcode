import XCTest
@testable import RxCode

@MainActor
final class BranchBriefingPromptContextTests: XCTestCase {
    func testBranchBriefingSystemPromptWrapsRecentWorkAsBackgroundContext() {
        let prompt = AppState.branchBriefingSystemPrompt(
            branch: "feature/search",
            briefing: "- Added natural-language thread search.\n- Updated indexing."
        )

        XCTAssertTrue(prompt.contains("# Current branch briefing"))
        XCTAssertTrue(prompt.contains("project's current branch (`feature/search`)"))
        XCTAssertTrue(prompt.contains("- Added natural-language thread search."))
        XCTAssertTrue(prompt.contains("may be incomplete or slightly out of date"))
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
}
