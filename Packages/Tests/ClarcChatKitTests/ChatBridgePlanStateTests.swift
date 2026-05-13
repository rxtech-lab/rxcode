import Testing
import ClarcCore
@testable import ClarcChatKit

@MainActor
@Suite("ChatBridge plan-state helpers")
struct ChatBridgePlanStateTests {

    // MARK: - isPlanDecided

    @Test("Accepted prefixes are decided")
    func acceptedPrefixesAreDecided() {
        for prefix in PlanCardView.userDecisionPrefixes {
            let tc = makeExitPlanToolCall(result: prefix)
            #expect(PlanCardView.isPlanDecided(tc), "expected \"\(prefix)\" to be decided")
        }
    }

    @Test("Rejected with feedback suffix is decided")
    func rejectedWithFeedbackIsDecided() {
        let tc = makeExitPlanToolCall(result: "Rejected: use SQLite instead of Postgres")
        #expect(PlanCardView.isPlanDecided(tc))
    }

    @Test("Nil result is not decided")
    func nilResultNotDecided() {
        let tc = makeExitPlanToolCall(result: nil)
        #expect(!PlanCardView.isPlanDecided(tc))
    }

    @Test("Arbitrary CLI text is not decided")
    func cliTextNotDecided() {
        // The CLI itself can leave non-user-decision text in `result` before the
        // user has clicked anything; that must not be treated as decided.
        let tc = makeExitPlanToolCall(result: "Exit plan mode?")
        #expect(!PlanCardView.isPlanDecided(tc))
    }

    @Test("Empty result is not decided")
    func emptyResultNotDecided() {
        let tc = makeExitPlanToolCall(result: "")
        #expect(!PlanCardView.isPlanDecided(tc))
    }

    // MARK: - hasPendingPlanDecision

    @Test("No messages → no pending decision")
    func emptyMessagesNoPending() {
        let bridge = ChatBridge()
        bridge.messages = []
        #expect(!bridge.hasPendingPlanDecision)
    }

    @Test("Pending ExitPlanMode → has pending decision")
    func pendingExitPlanModeIsDetected() {
        let bridge = ChatBridge()
        bridge.messages = [
            makeAssistantMessage(toolCall: makeExitPlanToolCall(result: nil)),
        ]
        #expect(bridge.hasPendingPlanDecision)
    }

    @Test("Decided ExitPlanMode → no pending decision")
    func decidedExitPlanModeNoPending() {
        let bridge = ChatBridge()
        bridge.messages = [
            makeAssistantMessage(toolCall: makeExitPlanToolCall(result: "Accepted with Edits")),
        ]
        #expect(!bridge.hasPendingPlanDecision)
    }

    @Test("Older pending plan does not count if a newer plan was decided")
    func newestDecidedTakesPrecedence() {
        // Reverse-scan stops at the newest ExitPlanMode call. A decided new card
        // unlocks the input even if some earlier turn had a "pending" record.
        let bridge = ChatBridge()
        bridge.messages = [
            makeAssistantMessage(toolCall: makeExitPlanToolCall(id: "old", result: nil)),
            makeAssistantMessage(toolCall: makeExitPlanToolCall(id: "new", result: "Accepted with Edits")),
        ]
        #expect(!bridge.hasPendingPlanDecision)
    }

    @Test("Non-ExitPlanMode tool calls are ignored")
    func unrelatedToolCallsIgnored() {
        let bridge = ChatBridge()
        let other = ToolCall(id: "x", name: "Bash", input: [:], result: nil, isError: false)
        bridge.messages = [makeAssistantMessage(toolCall: other)]
        #expect(!bridge.hasPendingPlanDecision)
    }

    // MARK: - Helpers

    private func makeExitPlanToolCall(
        id: String = "tool-1",
        result: String?
    ) -> ToolCall {
        ToolCall(
            id: id,
            name: "ExitPlanMode",
            input: ["plan": .string("# Plan\n- step 1")],
            result: result,
            isError: false
        )
    }

    private func makeAssistantMessage(toolCall: ToolCall) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            blocks: [.toolCall(toolCall)]
        )
    }
}
