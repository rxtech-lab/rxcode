import XCTest
import RxCodeCore
@testable import RxCode

@MainActor
final class PlanDecisionTests: XCTestCase {

    // MARK: - Accept variants → "Proceed with the plan."

    func testAcceptAsk_sendsProceedPrompt() {
        XCTAssertEqual(
            AppState.continuationPrompt(for: .acceptAsk),
            "Proceed with the plan."
        )
    }

    func testAcceptWithEdits_sendsProceedPrompt() {
        XCTAssertEqual(
            AppState.continuationPrompt(for: .acceptWithEdits),
            "Proceed with the plan."
        )
    }

    func testAcceptAutoApprove_sendsProceedPrompt() {
        XCTAssertEqual(
            AppState.continuationPrompt(for: .acceptAutoApprove),
            "Proceed with the plan."
        )
    }

    // MARK: - Reject with feedback → revision prompt

    func testRejectWithFeedback_includesFeedbackInPrompt() {
        let result = AppState.continuationPrompt(
            for: .rejectWithFeedback(reason: "use SQLite instead of Postgres")
        )
        XCTAssertNotNil(result)
        XCTAssertTrue(
            result?.contains("use SQLite instead of Postgres") ?? false,
            "Continuation prompt should embed the user's feedback verbatim"
        )
    }

    func testRejectWithFeedback_trimsWhitespace() {
        let result = AppState.continuationPrompt(
            for: .rejectWithFeedback(reason: "   add tests please  \n")
        )
        XCTAssertEqual(
            result,
            "Revise the plan based on this feedback: add tests please"
        )
    }

    func testRejectWithFeedback_emptyReason_returnsNil() {
        XCTAssertNil(
            AppState.continuationPrompt(for: .rejectWithFeedback(reason: "")),
            "Empty feedback should behave like a plain reject — no continuation"
        )
    }

    func testRejectWithFeedback_whitespaceOnlyReason_returnsNil() {
        XCTAssertNil(
            AppState.continuationPrompt(for: .rejectWithFeedback(reason: "   \n  ")),
            "Whitespace-only feedback should behave like a plain reject"
        )
    }

    // MARK: - Plain reject → no continuation

    func testReject_returnsNil() {
        XCTAssertNil(AppState.continuationPrompt(for: .reject))
    }
}
