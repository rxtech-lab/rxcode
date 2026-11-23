import XCTest
import RxCodeCore
@testable import RxCode

extension CodingPlanTests {
    func testReviewPanelDebatesRevisesAndPasses() async throws {
        let (review, requests) = try await runImplementationReview([
            "CHANGES NEEDED\nAdd an atomic write test.", "PASS\nReload works.",
            "PASS\nAtomic write test passed.", "PASS\nReload still works."
        ], seats: 2)
        XCTAssertTrue(review.passed)
        XCTAssertEqual(review.responses.map(\.round), [1, 1, 2, 2])
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.last?.prompt.contains("Add an atomic write test.") == true)
        let critics = await (state.agentBackendOverrides[.acp] as! MockAgentBackend).receivedRequests
        XCTAssertTrue(critics[1].prompt.contains("Add an atomic write test."))
        XCTAssertTrue(critics.allSatisfy { $0.cwd == repo.path && $0.permissionMode == .plan })
    }

    func testThirdChangePlanIsAppliedWithoutAFourthReview() async throws {
        let (review, requests) = try await runImplementationReview(
            (1...3).map { "CHANGES NEEDED\nFix issue \($0)." }, seats: 1)
        XCTAssertEqual(review.responses.map(\.round), [1, 2, 3])
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.last?.prompt.contains("Fix issue 3.") == true)
        XCTAssertEqual(review.status, "Final revision finished · awaiting verification")
        XCTAssertFalse(review.passed)
    }

    func testMalformedVerdictStopsWithoutRevision() async throws {
        let (review, requests) = try await runImplementationReview(["Possibly pass"], seats: 1)
        XCTAssertTrue(review.status.hasPrefix("Review interrupted"))
        XCTAssertFalse(review.passed)
        XCTAssertEqual(requests.count, 1)
    }

    private func runImplementationReview(_ replies: [String], seats: Int) async throws
        -> (CodingPlanImplementationReview, [BackendSendRequest]) {
        let critics = backend(.acp), implementer = backend(.flowcy)
        let threadID = UUID().uuidString
        for reply in replies { await answer(reply, using: critics) }
        for _ in 0...3 {
            await implementer.enqueueScript([.systemInit(sessionId: threadID), .assistantText("Updated storage."),
                                             .result(sessionId: threadID)], forCwd: repo.path)
        }
        var plan = CodingPlan(id: UUID(), goal: "Save settings", source: "", configuration: .init(
            planner: planner, reviewers: (1...seats).map { .init(model: reviewer, prompt: "Check storage \($0)") }))
        plan.finish(.draft, text: "Write atomically.")
        plan.finish(.reconcile, text: "Write atomically and reload.")
        let source = ChatSession(id: plan.id.uuidString, projectId: project.id, title: plan.goal)
        state.threadStore.upsert(source.summary)
        try state.threadStore.saveCodingPlan(plan)
        window.currentSessionId = source.id
        let version = try XCTUnwrap(plan.versions.last)
        let model = AgentModel(provider: .flowcy, id: "implementer", displayName: "Implementer")
        let stream = await state.implementCodingPlan(CodingPlanRoom(plan), versionID: version.id, model: model, in: window)
        XCTAssertNotNil(stream)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let review = state.threadStore.codingPlan(for: threadID)?.implementationReview,
               review.passed || review.status.hasPrefix("Final revision") || review.status.hasPrefix("Review interrupted") {
                XCTAssertNil(state.threadStore.codingPlan(for: source.id)?.implementationReview)
                return (review, await implementer.receivedRequests)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw PlanningTurnError(message: "Timed out waiting for the implementation review.")
    }
}
