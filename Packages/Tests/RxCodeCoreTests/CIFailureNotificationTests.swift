import Foundation
import Testing
@testable import RxCodeCore

struct CIFailureNotificationTests {
    private func status(_ runs: [(String, Int, String)], state: CIOverallState = .failure, omitFailing: Bool = false, lastUpdated: String = "poll-time", headSha: String? = "same-commit") -> ProjectCIStatus {
        ProjectCIStatus(
            owner: "rxlab", repo: "RxCode", branch: "main", found: true,
            overallState: state, lastUpdated: lastUpdated, headSha: headSha,
            prNumber: nil, prState: nil, prUrl: nil,
            workflows: runs.map { name, run, updated in
                CIWorkflowStatus(workflowName: name, workflowId: nil, status: "completed",
                                 conclusion: "failure", htmlUrl: "https://github.com/rxlab/RxCode/actions/runs/\(run)",
                                 runNumber: run, updatedAt: updated)
            },
            failing: omitFailing ? [] : runs.map { name, run, _ in
                CIFailingWorkflow(workflowName: name, htmlUrl: "https://github.com/rxlab/RxCode/actions/runs/\(run)")
            }
        )
    }

    @Test func failureEventsSurvivePollingRecoveryAndRelaunch() throws {
        var ledger = CIFailureEventLedger()
        let failed = status([("Build", 100, "finished")])
        #expect(ledger.consume(failed).count == 1)
        #expect(ledger.consume(failed).isEmpty)
        #expect(ledger.consume(status([], state: .success)).isEmpty)
        ledger = try JSONDecoder().decode(CIFailureEventLedger.self, from: JSONEncoder().encode(ledger))
        #expect(ledger.consume(failed).isEmpty)
    }

    @Test func separateWorkflowsAndRerunsOnSameCommitAreAnnounced() {
        var ledger = CIFailureEventLedger()
        _ = ledger.consume(status([("Build", 100, "finished")]))
        let additional = status([("Build", 100, "finished"), ("Tests", 101, "finished")])
        #expect(ledger.consume(additional).map(\.workflowName) == ["Tests"])
        #expect(ledger.consume(status([("Tests", 101, "second-attempt")])).count == 1)
        #expect(ledger.consume(status([("Tests", 102, "finished")])).count == 1)
        #expect(ledger.consume(additional).isEmpty)
    }

    @Test func sparseFailureDoesNotRepeatWhenPollTimestampChanges() {
        var ledger = CIFailureEventLedger()
        #expect(ledger.consume(status([], lastUpdated: "first-poll", headSha: nil)).count == 1)
        #expect(ledger.consume(status([], lastUpdated: "second-poll", headSha: nil)).isEmpty)
    }

    @Test func rawWorkflowRetainsAvailableNameAndLink() {
        var ledger = CIFailureEventLedger()
        let raw = status([("Build", 100, "finished")], omitFailing: true)
        let events = ledger.consume(raw)
        #expect(events.first?.workflowName == "Build")
        #expect(events.first?.htmlUrl == "https://github.com/rxlab/RxCode/actions/runs/100")
        #expect(ledger.consume(status([("Build", 100, "finished")])).isEmpty)
    }

    @Test func legacyPayloadDecodesAndSpeechUsesOnlyEventFacts() throws {
        let legacy = Data(#"{"projectName":"RxCode","failingWorkflowNames":["Build"]}"#.utf8)
        let payload = try JSONDecoder().decode(CIFailedPayload.self, from: legacy)
        #expect(payload.detailsURL == nil)
        #expect(payload.spokenSummary == "GitHub Actions CI failed in RxCode: Build.")
        let unnamed = CIFailedPayload(projectId: nil, projectName: nil, failingWorkflowNames: [" "])
        #expect(unnamed.spokenSummary == "GitHub Actions CI failed in a monitored project.")
    }

    @Test func summaryStaysConciseAndLinkIsPreserved() {
        let url = "https://github.com/rxlab/RxCode/actions/runs/100"
        let payload = CIFailedPayload(projectId: nil, projectName: "RxCode",
                                      failingWorkflowNames: ["Build", "Tests", "Lint", "Release"], runURL: url)
        #expect(payload.spokenSummary == "GitHub Actions CI failed in RxCode: Build, Tests, Lint and 1 more workflow.")
        #expect(payload.detailsURL?.absoluteString == url)
        #expect(CIFailedPayload(projectId: nil, projectName: nil, failingWorkflowNames: [], runURL: "file:///tmp/test").detailsURL == nil)
    }
}
