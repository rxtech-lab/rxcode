import XCTest
import ClarcCore
@testable import ClarcChatKit

@MainActor
final class InputBarDisableTests: XCTestCase {

    // MARK: - hasPendingPlanDecision drives the input lock

    func testHasPendingPlanDecision_noMessages() {
        let bridge = ChatBridge()
        bridge.messages = []
        XCTAssertFalse(bridge.hasPendingPlanDecision)
    }

    func testHasPendingPlanDecision_undecidedPlan_isTrue() {
        let bridge = ChatBridge()
        bridge.messages = [
            makeAssistantMessage(toolCall: makeExitPlanToolCall(result: nil)),
        ]
        XCTAssertTrue(bridge.hasPendingPlanDecision,
                      "Input must lock while the latest plan card is awaiting a decision")
    }

    func testHasPendingPlanDecision_decidedPlan_isFalse() {
        let bridge = ChatBridge()
        bridge.messages = [
            makeAssistantMessage(toolCall: makeExitPlanToolCall(result: "Accepted with Edits")),
        ]
        XCTAssertFalse(bridge.hasPendingPlanDecision,
                       "Input must unlock once the plan is decided")
    }

    func testHasPendingPlanDecision_rejectedWithFeedback_isFalse() {
        let bridge = ChatBridge()
        bridge.messages = [
            makeAssistantMessage(toolCall: makeExitPlanToolCall(result: "Rejected: try SQLite")),
        ]
        XCTAssertFalse(bridge.hasPendingPlanDecision)
    }

    func testHasPendingPlanDecision_cliNoiseInResult_isTrue() {
        // "Exit plan mode?" is CLI-side text, not a user decision summary —
        // the input must stay locked until the user actually clicks something.
        let bridge = ChatBridge()
        bridge.messages = [
            makeAssistantMessage(toolCall: makeExitPlanToolCall(result: "Exit plan mode?")),
        ]
        XCTAssertTrue(bridge.hasPendingPlanDecision)
    }

    func testHasPendingPlanDecision_onlyLatestPlanMatters() {
        // A newer decided plan unlocks the input even if an earlier plan is still
        // recorded as pending in the message history.
        let bridge = ChatBridge()
        bridge.messages = [
            makeAssistantMessage(toolCall: makeExitPlanToolCall(id: "old", result: nil)),
            makeAssistantMessage(toolCall: makeExitPlanToolCall(id: "new", result: "Accepted with Edits")),
        ]
        XCTAssertFalse(bridge.hasPendingPlanDecision)
    }

    func testHasPendingPlanDecision_ignoresUnrelatedToolCalls() {
        let bridge = ChatBridge()
        let bash = ToolCall(id: "x", name: "Bash", input: [:], result: nil, isError: false)
        bridge.messages = [makeAssistantMessage(toolCall: bash)]
        XCTAssertFalse(bridge.hasPendingPlanDecision)
    }

    // MARK: - Helpers

    private func makeExitPlanToolCall(
        id: String = "tool-1",
        result: String?
    ) -> ToolCall {
        ToolCall(
            id: id,
            name: "ExitPlanMode",
            input: ["plan": .string("# Plan")],
            result: result,
            isError: false
        )
    }

    private func makeAssistantMessage(toolCall: ToolCall) -> ChatMessage {
        ChatMessage(role: .assistant, blocks: [.toolCall(toolCall)])
    }
}
