import Foundation
import RxCodeCore
import SwiftData
import os

/// The implementation thread carries a handoff copy of the debate. Prefer the
/// original, but allow the copy to recover history if its source was deleted.
private nonisolated struct StoredCodingPlan: Sendable {
    let plan: CodingPlan
    let source: ChatSession.Summary
    let implementation: ChatSession.Summary?
    let branch: String?
    let completionCheck: ChatSession.Summary?
}

private extension ThreadStoreReader {
    func codingPlans(projectID: UUID?, threadID: String?) async throws -> [StoredCodingPlan] {
        let result = await read { context in
            Result {
                let predicate: Predicate<ChatThread>
                if let threadID {
                    let id = UUID(uuidString: threadID)?.uuidString ?? threadID
                    let row = try context.fetch(FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == threadID || $0.id == id })).first
                    guard let planID = row?.implementationPlanID ?? UUID(uuidString: id) else { return [StoredCodingPlan]() }
                    let sourceID = planID.uuidString
                    predicate = #Predicate { $0.id == sourceID || $0.implementationPlanID == planID }
                } else if let projectID {
                    predicate = #Predicate { $0.projectId == projectID && $0.codingPlanData != nil }
                } else {
                    predicate = #Predicate { $0.codingPlanData != nil }
                }
                let rows = try context.fetch(FetchDescriptor(predicate: predicate, sortBy: [
                    SortDescriptor(\ChatThread.updatedAt, order: .reverse), SortDescriptor(\ChatThread.id)
                ]))
                var groups: [UUID: [ChatThread]] = [:]
                for row in rows where projectID == nil || row.projectId == projectID {
                    guard let id = row.implementationPlanID ?? UUID(uuidString: row.id) else { continue }
                    groups[id, default: []].append(row)
                }
                return try groups.compactMap { id, group in
                    let child = group.first { $0.implementationPlanID == id }
                    guard let source = group.first(where: { $0.id == id.uuidString }) ?? child,
                          let data = source.codingPlanData ?? child?.codingPlanData else { return nil }
                    let plan: CodingPlan
                    do {
                        plan = try JSONDecoder().decode(CodingPlan.self, from: data)
                    } catch {
                        if source.id != child?.id, let copy = child?.codingPlanData,
                           let recovered = try? JSONDecoder().decode(CodingPlan.self, from: copy) {
                            plan = recovered
                        } else if threadID != nil {
                            throw IDEToolError.handlerFailed("Could not decode saved coding plan \(id).")
                        } else {
                            Logger(subsystem: "com.claudework", category: "CodingPlans").error(
                                "Skipping unreadable plan \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                            )
                            return nil
                        }
                    }
                    var completionCheck: ChatSession.Summary?
                    if let child {
                        let parent = child.id
                        let verified = TaskCompletionCheckLabel.verified
                        let unverified = TaskCompletionCheckLabel.unverified
                        let checking = TaskCompletionCheckLabel.inProgress
                        var checks = FetchDescriptor<ChatThread>(predicate: #Predicate {
                            $0.parentThreadId == parent && ($0.threadLabel == verified || $0.threadLabel == unverified || $0.threadLabel == checking)
                        }, sortBy: [SortDescriptor(\.createdAt, order: .reverse), SortDescriptor(\.id)])
                        checks.fetchLimit = 1
                        completionCheck = try context.fetch(checks).first?.toSummary()
                    }
                    return StoredCodingPlan(plan: plan, source: source.toSummary(), implementation: child?.toSummary(),
                                            branch: source.worktreeBranch ?? source.checkoutBranch, completionCheck: completionCheck)
                }
            }
        }
        return try result.get()
    }
}

struct CodingPlanReadResult {
    let activity: CodingPlanActivity
    let versions: [CodingPlan.Version]
}

extension AppState {
    func codingPlanActivities(projectID: UUID? = nil, threadID: String? = nil) async throws -> [CodingPlanActivity] {
        try await readCodingPlans(projectID: projectID, threadID: threadID).map(\.activity)
    }

    func readCodingPlans(projectID: UUID?, threadID: String?) async throws -> [CodingPlanReadResult] {
        let reader = ThreadStoreReader(container: threadStore.container)
        let saved = try await reader.codingPlans(projectID: projectID, threadID: threadID)
        var boards = taskBoards
        for project in Set(saved.compactMap { $0.implementation?.projectId }) where boards[project] == nil {
            let persisted = await persistence.loadTaskBoard(projectId: project)
            boards[project] = taskBoards[project] ?? persisted
        }
        return saved.map { record in
            let source = record.source
            let plan = codingPlanRooms[record.plan.id]?.plan ?? record.plan
            let current = plan.versions.last
            let selected = plan.versions.first { $0.id == plan.approvedVersionID } ?? current
            let status: String
            if plan.approvedVersionID != nil {
                status = "approved"
            } else if plan.lastError != nil {
                status = "interrupted"
            } else if plan.nextStep == nil && current != nil {
                status = "ready"
            } else {
                status = "drafting"
            }
            let evidence = implementationEvidence(for: record, board: boards[source.projectId], approved: plan.approvedVersionID != nil)
            let planUpdated = record.plan.updatedAt ?? source.updatedAt
            let updated = max(planUpdated, record.implementation?.updatedAt ?? planUpdated, evidence.updatedAt ?? planUpdated)
            let title = source.id == plan.id.uuidString ? source.title : ChatSession.placeholderTitle(from: plan.goal)
            let activity = CodingPlanActivity(
                id: plan.id, threadID: source.id, projectID: source.projectId, title: title, goal: plan.goal,
                branch: record.branch ?? ciBranchesBySessionId[source.id]?.first, createdAt: source.createdAt, updatedAt: updated,
                planningStatus: status, implementationStatus: evidence.status, implementationEvidence: evidence.reason,
                implementationThreadID: record.implementation?.id, currentVersionID: current?.id,
                currentVersionTitle: current?.title, approvedVersionID: plan.approvedVersionID,
                versionCount: plan.versions.count, featureExcerpt: Self.codingPlanExcerpt(selected?.markdown, goal: plan.goal),
                approvedVersionTitle: plan.approvedVersionID == selected?.id ? selected?.title : nil
            )
            return CodingPlanReadResult(activity: activity, versions: plan.versions)
        }.sorted {
            if $0.activity.updatedAt == $1.activity.updatedAt { return $0.activity.id.uuidString < $1.activity.id.uuidString }
            return $0.activity.updatedAt > $1.activity.updatedAt
        }
    }

    /// Extract a short passage suitable for both briefings and speech. Keep code
    /// examples, the document title and unrelated sections out of the excerpt.
    nonisolated static func codingPlanExcerpt(_ markdown: String?, goal: String) -> String {
        var preferred: [String] = []
        var fallback: [String] = []
        var inFeatureSection = false
        var fence: String?
        for raw in (markdown ?? "").split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = String(line.prefix(3))
            if marker == "```" || marker == "~~~" {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            guard fence == nil, !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).lowercased()
                let words = heading.split(whereSeparator: { !$0.isLetter })
                inFeatureSection = !heading.contains("out of scope") && !heading.contains("non-goal") &&
                    !Set(words).isDisjoint(with: ["objective", "objectives", "features", "scope", "goals"])
                continue
            }
            guard !line.hasPrefix("|"), !line.hasPrefix("<!--"), line != "---" else { continue }
            if fallback.count < 4 { fallback.append(line) }
            if inFeatureSection { preferred.append(line) }
            if preferred.count == 4 { break }
        }
        let lines = preferred.isEmpty ? fallback : preferred
        let excerpt = lines.isEmpty ? goal : lines.joined(separator: "\n")
        guard excerpt.count > 480 else { return excerpt }
        let prefix = excerpt.prefix(479)
        let end = prefix.lastIndex(where: \.isWhitespace) ?? prefix.endIndex
        return String(prefix[..<end]) + "…"
    }

    private func implementationEvidence(for record: StoredCodingPlan, board: TaskBoard?, approved: Bool)
        -> (status: String, reason: String, updatedAt: Date?) {
        guard let child = record.implementation else {
            if approved { return ("unknown", "The approved plan's implementation thread is unavailable.", nil) }
            return ("unimplemented", "No recorded implementation handoff.", nil)
        }
        let key = resolveCurrentSessionId(child.id)
        let board = board ?? TaskBoard()
        let tasks = board.tasks.filter { $0.sessionKey.map(resolveCurrentSessionId) == key }
        let updated = (tasks.map(\.updatedAt) + [record.completionCheck?.updatedAt].compactMap { $0 }).max()
        if sessionActivity[key]?.isStreaming == true {
            return ("in_progress", "The linked implementation thread is running.", updated)
        }
        if !tasks.isEmpty && tasks.allSatisfy({ board.column(for: $0.status).countsAsDone && $0.attentionReason == nil }) {
            return ("implemented", "All board tasks run in the linked implementation thread are marked done.", updated)
        }
        if tasks.contains(where: { board.column(for: $0.status).triggersChat && !$0.isQueued && $0.attentionReason == nil }) {
            return ("in_progress", "A linked implementation task is in an active board column.", updated)
        }
        if let check = record.completionCheck {
            switch taskCompletionCheckState(for: check) {
            case .verifying:
                return ("in_progress", "The linked implementation completion check is running.", updated)
            case .verified where tasks.count <= 1 && tasks.allSatisfy({ $0.status == .pendingReview && $0.attentionReason == nil }):
                return ("implemented", "The linked implementation thread's completion check verified the task.", updated)
            case .unverified:
                return ("unknown", "The latest linked implementation completion check did not verify completion.", updated)
            default: break
            }
        }
        return ("unknown", "A linked implementation thread exists without a confirmed outcome.", updated)
    }
}
