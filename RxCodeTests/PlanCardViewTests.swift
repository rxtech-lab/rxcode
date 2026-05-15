import XCTest
import SwiftUI
import ViewInspector
import RxCodeCore
@testable import RxCodeChatKit

// Bridge the inspection helper inside `PlanSheetView` to ViewInspector's
// emissary protocol so tests can wait on @State transitions (e.g. composer reveal).
extension PlanSheetInspection: InspectionEmissary {}

@MainActor
final class PlanCardViewTests: XCTestCase {

    // MARK: - PlanCardView chip: tapping "Review" calls onOpen with tool call id

    func testChip_tappingReview_callsOnOpenWithToolCallId() throws {
        var openedId: String?
        let chip = makeChip(result: nil, onOpen: { openedId = $0 })

        try chip.inspect().find(button: "Review").tap()

        XCTAssertEqual(
            openedId,
            "tool-1",
            "Tapping the chip's Review button must invoke onOpen with the chip's tool call id"
        )
    }

    // MARK: - PlanCardView chip: decided plan shows summary + 'View' label

    func testChip_decidedPlan_showsSummaryAndViewLabel() throws {
        var openedId: String?
        let chip = makeChip(result: "Accepted with Edits", onOpen: { openedId = $0 })

        let labels = try chip.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertTrue(
            labels.contains("Accepted with Edits"),
            "Decided chip should display the decision summary verbatim. Labels: \(labels)"
        )
        XCTAssertTrue(
            labels.contains("View"),
            "Decided chip should swap the action label from 'Review' to 'View'. Labels: \(labels)"
        )

        // Decided chip's button should still be tappable and re-open the sheet.
        try chip.inspect().find(button: "View").tap()
        XCTAssertEqual(
            openedId,
            "tool-1",
            "Decided chip should still open the read-only sheet on tap"
        )
    }

    // MARK: - PlanCardView chip: CLI noise must not flip to "decided" state

    func testChip_cliNoiseInResult_stillShowsReview() throws {
        // The CLI itself can write non-user-decision text to `result` before the
        // user has clicked anything — that must NOT make the chip render as decided.
        let chip = makeChip(result: "Exit plan mode?", onOpen: { _ in })

        let labels = try chip.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertTrue(
            labels.contains("Plan ready"),
            "Chip should show 'Plan ready' when result is unrelated CLI text. Labels: \(labels)"
        )
        XCTAssertTrue(
            labels.contains("Review"),
            "Chip should show the 'Review' action label when not decided. Labels: \(labels)"
        )
    }

    // MARK: - PlanSheetView: tapping "Accept Edits" calls onSubmit with the right action

    func testSheet_tappingAcceptEdits_callsOnSubmitWithAcceptWithEdits() throws {
        var captured: (String, PlanDecisionAction)?
        let sheet = makeSheet(
            decided: false,
            onSubmit: { id, action in captured = (id, action) }
        )
        ViewHosting.host(view: sheet)
        defer { ViewHosting.expel() }

        try sheet.inspect().find(button: "Accept Edits").tap()

        XCTAssertNotNil(captured, "onSubmit must fire when 'Accept Edits' is tapped")
        XCTAssertEqual(captured?.0, "tool-1", "onSubmit should pass through the plan's tool call id")
        XCTAssertEqual(
            captured?.1,
            .acceptWithEdits,
            "Tapping 'Accept Edits' must dispatch .acceptWithEdits"
        )
    }

    // MARK: - PlanSheetView: tapping "Accept + Auto" dispatches .acceptAutoApprove

    func testSheet_tappingAcceptPlusAuto_callsOnSubmitWithAcceptAutoApprove() throws {
        var captured: (String, PlanDecisionAction)?
        let sheet = makeSheet(
            decided: false,
            onSubmit: { id, action in captured = (id, action) }
        )
        ViewHosting.host(view: sheet)
        defer { ViewHosting.expel() }

        try sheet.inspect().find(button: "Accept + Auto").tap()

        XCTAssertEqual(captured?.1, .acceptAutoApprove)
    }

    // MARK: - PlanSheetView: plain Reject dispatches .reject

    func testSheet_tappingReject_callsOnSubmitWithReject() throws {
        var captured: (String, PlanDecisionAction)?
        let sheet = makeSheet(
            decided: false,
            onSubmit: { id, action in captured = (id, action) }
        )
        ViewHosting.host(view: sheet)
        defer { ViewHosting.expel() }

        try sheet.inspect().find(button: "Reject").tap()

        XCTAssertEqual(captured?.1, .reject)
    }

    // MARK: - PlanSheetView: Reject with Reason → composer → submit feedback

    // The full flow (tap "Reject with Reason" → @State swap → type → send) is
    // split across two tests because driving the `decisionButtons → feedbackComposer`
    // view swap on a hosted view double-frees memory when another `PlanSheetView`
    // was hosted+expelled earlier in the same xctest run. The two halves below
    // exercise the same behavior without forcing the swap inside the hosted tree.

    func testSheet_tappingRejectWithReason_doesNotSubmit() throws {
        var submitCalled = false
        let sheet = makeSheet(
            decided: false,
            onSubmit: { _, _ in submitCalled = true }
        )
        ViewHosting.host(view: sheet)
        defer { ViewHosting.expel() }

        try sheet.inspect().find(button: "Reject with Reason").tap()

        XCTAssertFalse(
            submitCalled,
            "Tapping 'Reject with Reason' must reveal the composer, NOT resolve the CLI hook"
        )
    }

    func testSheet_sendFeedbackFromComposer_dispatchesRejectWithFeedback() throws {
        var captured: (String, PlanDecisionAction)?
        // Pre-populate the feedback so the "Send feedback" button is enabled.
        // The text-entry path is covered separately via SwiftUI's own Binding —
        // here we verify the submit dispatch passes the typed reason through.
        let sheet = makeSheetWithComposer(
            initialFeedback: "use SQLite instead",
            onSubmit: { id, action in captured = (id, action) }
        )
        ViewHosting.host(view: sheet)
        defer { ViewHosting.expel() }

        let labels = try sheet.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }
        XCTAssertTrue(
            labels.contains("Tell Claude what to change"),
            "Composer header must be visible when initialIsComposingFeedback is true. Labels: \(labels)"
        )

        try sheet.inspect().find(button: "Send feedback").tap()

        XCTAssertEqual(captured?.0, "tool-1")
        XCTAssertEqual(
            captured?.1,
            .rejectWithFeedback(reason: "use SQLite instead"),
            "Submitting the feedback composer must dispatch .rejectWithFeedback with the typed reason"
        )
    }

    // MARK: - PlanSheetView: closing the sheet calls onClose, NOT onSubmit

    func testSheet_close_callsOnCloseAndNotOnSubmit() throws {
        var submitCalled = false
        var closeCalled = false
        let sheet = makeSheet(
            decided: false,
            onSubmit: { _, _ in submitCalled = true },
            onClose: { closeCalled = true }
        )
        ViewHosting.host(view: sheet)
        defer { ViewHosting.expel() }

        // The X button has no text label — find it by help string.
        let closeButton = try sheet.inspect().find(ViewType.Button.self) { btn in
            (try? btn.help().string()) == "Close — you can review later from the banner"
        }
        try closeButton.tap()

        XCTAssertTrue(closeCalled, "Tapping X must call onClose")
        XCTAssertFalse(submitCalled, "Closing the sheet must NOT count as decline — onSubmit must remain unfired")
    }

    // MARK: - PlanSheetView: decided plan shows summary + hides decision buttons

    func testSheet_decidedPlan_showsSummaryAndHidesButtons() throws {
        let sheet = makeSheet(decided: true, summary: "Accepted with Edits")
        ViewHosting.host(view: sheet)
        defer { ViewHosting.expel() }

        let labels = try sheet.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertTrue(
            labels.contains("Accepted with Edits"),
            "Decided footer must contain the action summary. Labels: \(labels)"
        )

        // Buttons must be gone.
        XCTAssertThrowsError(
            try sheet.inspect().find(button: "Accept + Auto"),
            "Decided sheet must hide the Accept + Auto button"
        )
        XCTAssertThrowsError(
            try sheet.inspect().find(button: "Reject"),
            "Decided sheet must hide the Reject button"
        )
    }

    // MARK: - Helpers

    private let planMd = "# My plan\n- step 1\n- step 2"

    private func makeChip(
        result: String?,
        planMarkdown: String = "# My plan\n- step 1\n- step 2",
        onOpen: ((String) -> Void)? = nil
    ) -> PlanCardView {
        let toolCall = ToolCall(
            id: "tool-1",
            name: "ExitPlanMode",
            input: ["plan": .string(planMarkdown)],
            result: result,
            isError: false
        )
        return PlanCardView(
            toolCall: toolCall,
            planMarkdown: planMarkdown,
            isMessageStreaming: false,
            onOpen: onOpen
        )
    }

    private func makeSheet(
        decided: Bool,
        summary: String? = nil,
        onSubmit: @escaping (String, PlanDecisionAction) -> Void = { _, _ in },
        onClose: @escaping () -> Void = { }
    ) -> PlanSheetView {
        let plan = PendingPlan(
            toolCallId: "tool-1",
            markdown: planMd,
            isStreaming: false,
            isDecided: decided,
            decisionSummary: decided ? (summary ?? "Accepted with Edits") : nil
        )
        return PlanSheetView(
            plan: plan,
            remainingCount: 0,
            onSubmit: onSubmit,
            onClose: onClose
        )
    }

    private func makeSheetWithComposer(
        initialFeedback: String,
        onSubmit: @escaping (String, PlanDecisionAction) -> Void = { _, _ in },
        onClose: @escaping () -> Void = { }
    ) -> PlanSheetView {
        let plan = PendingPlan(
            toolCallId: "tool-1",
            markdown: planMd,
            isStreaming: false,
            isDecided: false,
            decisionSummary: nil
        )
        return PlanSheetView(
            plan: plan,
            remainingCount: 0,
            initialFeedbackText: initialFeedback,
            initialIsComposingFeedback: true,
            onSubmit: onSubmit,
            onClose: onClose
        )
    }
}
