import Foundation
import RxCodeCore

nonisolated struct CodingPlanImplementationReview: Codable {
    static let maximumRounds = 3

    enum Verdict: String, Codable {
        case pass = "PASS"
        case changes = "CHANGES NEEDED"
    }

    struct Response: Codable {
        let round: Int
        let reviewer: String
        let verdict: Verdict
        let detail: String

        init(round: Int, reviewer: String, text: String) throws {
            let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(
                maxSplits: 1, whereSeparator: \.isNewline)
            guard let first = lines.first, let verdict = Verdict(rawValue: first.trimmingCharacters(in: .whitespaces).uppercased()),
                  lines.count == 2, !lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PlanningTurnError(message: "The reviewer returned an incomplete verdict or change plan.")
            }
            self.round = round
            self.reviewer = reviewer
            self.verdict = verdict
            self.detail = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var markdown: String { "### Turn \(round) · \(reviewer)\n\n**\(verdict.rawValue)**\n\n\(detail)" }
    }

    var responses: [Response] = []
    var status = "Waiting for review"
    var passed = false
    var pendingRound: Int? = 1

    func reviewerPrompt(version: CodingPlan.Version, reviewer: CodingPlan.Reviewer, implementation: String, round: Int) -> String {
        """
        Review the implementation in this working directory against the approved plan. Inspect the changed files and verification evidence.
        This is panel turn \(round) of \(Self.maximumRounds). Your assignment is \(reviewer.prompt)
        Address earlier reviewers' findings, including whether prior changes resolved them. Leave project files unchanged.
        On the first line write exactly PASS or CHANGES NEEDED. Then give Markdown evidence for a pass, or a concrete change plan with verification steps.

        Approved plan:
        \(version.markdown)

        Implementation report:
        \(implementation)

        Earlier review discussion:
        \(responses.map(\.markdown).joined(separator: "\n\n"))
        """
    }

    func revisionPrompt(round: Int) -> String? {
        let changes = responses.filter { $0.round == round && $0.verdict == .changes }
        guard !changes.isEmpty else { return nil }
        return "Apply the reviewers’ change plan to the implementation and verify the result against the approved plan.\n\n"
            + changes.map(\.markdown).joined(separator: "\n\n")
    }
}

extension AppState {
    func reviewFinishedImplementation(threadID: String, project: Project, cwd: String,
                                      implementation: String, userMessageID: UUID) async {
        guard var plan = threadStore.codingPlan(for: threadID), let approved = plan.approvedVersionID,
              let version = plan.versions.first(where: { $0.id == approved }),
              var review = plan.implementationReview, let round = review.pendingRound else { return }
        func save(_ status: String) throws {
            review.status = status
            plan.implementationReview = review
            try threadStore.saveImplementationReview(plan, threadID: threadID)
        }
        func isCurrent() async -> Bool {
            if sessionStates[threadID]?.messages.isEmpty != false,
               let summary = threadStore.fetch(id: threadID)?.toSummary() {
                await hydrateSessionIfNeeded(summary: summary, project: project)
            }
            guard let state = sessionStates[threadID] else { return false }
            return !Task.isCancelled && !state.isStreaming && state.messages.last(where: { $0.role == .user })?.id == userMessageID
                && threadStore.fetch(id: threadID)?.implementationPlanID == plan.id
        }

        guard await isCurrent() else { return }
        review.pendingRound = nil
        do {
            guard round <= CodingPlanImplementationReview.maximumRounds else {
                try save("Final revision finished · awaiting verification")
                return
            }
            for (index, reviewer) in plan.configuration.reviewers.enumerated() {
                let name = "Reviewer \(index + 1) · \(reviewer.model.displayName)"
                try save("Turn \(round) · \(name)")
                let prompt = review.reviewerPrompt(version: version, reviewer: reviewer, implementation: implementation, round: round)
                let text = try await planningText(model: reviewer.model, prompt: prompt, cwd: cwd)
                guard await isCurrent() else { try save("Review interrupted"); return }
                review.responses.append(try .init(round: round, reviewer: name, text: text))
            }
            guard let revision = review.revisionPrompt(round: round) else {
                review.passed = true
                try save("Passed on turn \(round)")
                return
            }
            review.pendingRound = round + 1
            try save("Changes needed · revision requested after turn \(round)")
            let target = WindowState()
            target.currentSessionId = threadID
            target.selectedProject = project
            target.sessionPermissionMode = sessionStates[threadID]?.permissionMode
            target.sessionEffort = sessionStates[threadID]?.effort
            let stream = await sendPrompt(revision, in: target)
            if stream == nil { try save("Changes needed · revision did not start") }
        } catch {
            try? save("Review interrupted · \(error.localizedDescription)")
        }
    }
}
