import XCTest
import SwiftUI
import ViewInspector
import ClarcCore
@testable import ClarcChatKit

@MainActor
final class PlanCardViewTests: XCTestCase {

    // MARK: - Pending plan: decision buttons render

    func testDecisionButtons_visibleWhenNotDecided() throws {
        let card = makeCard(result: nil)
        let host = hosting(card)

        let labels = try host.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        for expected in [
            "Accept + Auto",
            "Accept Edits",
            "Accept Ask",
            "Reject with Reason",
            "Reject",
        ] {
            XCTAssertTrue(
                labels.contains(expected),
                "Expected decision button \"\(expected)\" to be present. Found: \(labels)"
            )
        }

        // The decided-row status text should NOT appear.
        XCTAssertFalse(
            labels.contains(where: { $0.hasPrefix("Accepted ") || $0.hasPrefix("Rejected") }),
            "Decided status text leaked into pending state. Labels: \(labels)"
        )
    }

    // MARK: - Accepted plan: buttons gone, status row shown

    func testAcceptedPlan_hidesButtons_showsStatus() throws {
        let card = makeCard(result: "Accepted with Edits")
        let host = hosting(card)

        let labels = try host.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertFalse(labels.contains("Accept + Auto"),
                       "Decision buttons must disappear once a plan is decided. Labels: \(labels)")
        XCTAssertFalse(labels.contains("Accept Edits"),
                       "Decision buttons must disappear once a plan is decided. Labels: \(labels)")
        XCTAssertFalse(labels.contains("Reject"),
                       "Decision buttons must disappear once a plan is decided. Labels: \(labels)")
        XCTAssertTrue(labels.contains("Accepted with Edits"),
                      "Decided status row must contain the action summary. Labels: \(labels)")
    }

    // MARK: - Rejected with feedback: status row shows feedback

    func testRejectedWithFeedback_showsFeedbackInStatus() throws {
        let summary = "Rejected: please use SQLite"
        let card = makeCard(result: summary)
        let host = hosting(card)

        let labels = try host.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertTrue(
            labels.contains(where: { $0.contains("please use SQLite") }),
            "Decided status row should embed the user's rejection feedback. Labels: \(labels)"
        )
    }

    // MARK: - CLI noise must not be treated as decided

    func testCliNoiseInResult_keepsButtonsVisible() throws {
        // The CLI itself can write non-user-decision text to `result` before the
        // user has clicked anything — that must NOT hide the accept/reject buttons.
        let card = makeCard(result: "Exit plan mode?")
        let host = hosting(card)

        let labels = try host.inspect()
            .findAll(ViewType.Text.self)
            .compactMap { try? $0.string() }

        XCTAssertTrue(
            labels.contains("Accept + Auto"),
            "Buttons should still render when result is unrelated CLI text. Labels: \(labels)"
        )
    }

    // MARK: - Helpers

    private func makeCard(
        result: String?,
        planMarkdown: String = "# My plan\n- step 1\n- step 2"
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
            isMessageStreaming: false
        )
    }

    private func hosting<V: View>(_ view: V) -> some View {
        view.environment(WindowState())
    }
}
