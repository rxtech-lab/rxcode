import Foundation
import RxCodeCore
import SwiftData

extension ThreadStore {
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
        source.codingPlanData = data
        var child: ChatThread?
        if let implementation {
            let row = ChatThread.from(implementation)
            row.codingPlanData = data
            row.implementationPlanID = plan.id
            context.insert(row)
            child = row
        }
        do {
            try context.save()
            onCodingPlansChanged?()
        } catch {
            source.codingPlanData = oldData
            if let child { context.delete(child) }
            throw error
        }
    }

    func implementationThread(for planID: UUID) -> String? {
        var query = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.implementationPlanID == planID })
        query.fetchLimit = 1
        return (try? context.fetch(query))?.first?.id
    }
}
