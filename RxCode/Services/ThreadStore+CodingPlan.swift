import Foundation
import RxCodeCore
import SwiftData

extension ThreadStore {
    /// Older plan goals were treated as unanswered chat messages during transcript recovery.
    func backfillCodingPlanTurnOutcomes() {
        let query = FetchDescriptor<ChatThread>(predicate: #Predicate {
            $0.implementationPlanID == nil && $0.codingPlanData != nil && $0.unfinishedTranscript == nil
        })
        guard let rows = try? context.fetch(query).filter({ $0.hasUnfinishedTurn != false }), !rows.isEmpty else { return }
        for row in rows { row.hasUnfinishedTurn = false }
        save()
    }

    func codingPlan(for threadID: String) -> CodingPlan? {
        guard let data = fetch(id: threadID)?.codingPlanData,
              var plan = try? JSONDecoder().decode(CodingPlan.self, from: data) else { return nil }
        plan.restoreVersionLinks()
        return plan
    }

    func saveCodingPlan(_ plan: CodingPlan, implementation: ChatSession.Summary? = nil) throws {
        guard let source = fetch(id: plan.id.uuidString) else {
            throw PlanningTurnError(message: "The planning thread has been deleted.")
        }
        var snapshot = plan
        snapshot.updatedAt = .now
        let data = try JSONEncoder().encode(snapshot)
        let oldData = source.codingPlanData
        var child: ChatThread?
        if let implementation {
            let row = ChatThread.from(implementation)
            if !snapshot.configuration.reviewers.isEmpty {
                snapshot.implementationReview = CodingPlanImplementationReview()
            }
            row.codingPlanData = try JSONEncoder().encode(snapshot)
            row.implementationPlanID = plan.id
            context.insert(row)
            child = row
        }
        source.codingPlanData = data
        do {
            try context.save()
            onCodingPlansChanged?()
        } catch {
            source.codingPlanData = oldData
            if let child { context.delete(child) }
            throw error
        }
    }

    func saveImplementationReview(_ plan: CodingPlan, threadID: String) throws {
        guard let child = fetch(id: threadID), child.implementationPlanID == plan.id else {
            throw PlanningTurnError(message: "The implementation thread has been deleted.")
        }
        let previous = child.codingPlanData
        var snapshot = plan
        snapshot.updatedAt = .now
        child.codingPlanData = try JSONEncoder().encode(snapshot)
        do {
            try context.save()
            onCodingPlansChanged?()
        } catch {
            child.codingPlanData = previous
            throw error
        }
    }

    func implementationThreads(for planID: UUID) -> [ChatSession.Summary] {
        let query = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.implementationPlanID == planID },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)])
        return (try? context.fetch(query))?.map { $0.toSummary() } ?? []
    }
}
