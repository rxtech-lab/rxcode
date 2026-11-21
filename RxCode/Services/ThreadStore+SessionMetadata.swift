import Foundation
import SwiftData
import RxCodeCore
import os

extension ThreadStore {
    // MARK: - Todo Snapshots

    func fetchTodoSnapshot(sessionId: String) -> TodoSnapshot? {
        var descriptor = FetchDescriptor<TodoSnapshot>(predicate: #Predicate { $0.sessionId == sessionId })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func loadTodoProgressBySession() -> [String: ChatTodoProgress] {
        var descriptor = FetchDescriptor<TodoSnapshot>()
        descriptor.propertiesToFetch = [\.sessionId, \.done, \.total, \.inProgress, \.updatedAt]
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.reduce(into: [:]) { result, row in
            result[row.sessionId] = ChatTodoProgress(
                done: row.done,
                total: row.total,
                inProgress: row.inProgress > 0,
                updatedAt: row.updatedAt
            )
        }
    }

    nonisolated static func todoListsBySession(in context: ModelContext) -> [String: TodoListSnapshot] {
        let descriptor = FetchDescriptor<TodoSnapshot>()
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.reduce(into: [:]) { result, row in
            result[row.sessionId] = row.list
        }
    }

    @discardableResult
    func upsertTodoSnapshot(sessionId: String, items: [TodoItem]) -> TodoListSnapshot {
        let snapshot = TodoListSnapshot(items: items, updatedAt: .now)
        if let existing = fetchTodoSnapshot(sessionId: sessionId) {
            existing.apply(items: items, at: snapshot.updatedAt)
        } else {
            context.insert(TodoSnapshot(sessionId: sessionId, items: items, updatedAt: snapshot.updatedAt))
        }
        save()
        return snapshot
    }

    func renameTodoSnapshot(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        guard let row = fetchTodoSnapshot(sessionId: oldId) else { return }
        if let existing = fetchTodoSnapshot(sessionId: newId) {
            context.delete(row)
            _ = existing
        } else {
            row.sessionId = newId
        }
        save()
    }

    func deleteTodoSnapshot(sessionId: String) {
        deleteTodoSnapshotRow(sessionId: sessionId)
        save()
    }

    func deleteTodoSnapshotRow(sessionId: String) {
        guard let row = fetchTodoSnapshot(sessionId: sessionId) else { return }
        context.delete(row)
    }

    // MARK: - Plan Decisions

    private func fetchPlanDecision(sessionId: String, toolCallId: String) -> PlanDecisionRecord? {
        var descriptor = FetchDescriptor<PlanDecisionRecord>(
            predicate: #Predicate { $0.sessionId == sessionId && $0.toolCallId == toolCallId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func loadPlanDecisions(sessionId: String) -> [String: String] {
        let descriptor = FetchDescriptor<PlanDecisionRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        var map: [String: String] = [:]
        for row in rows { map[row.toolCallId] = row.summary }
        return map
    }

    func setPlanDecision(sessionId: String, toolCallId: String, summary: String) {
        if let existing = fetchPlanDecision(sessionId: sessionId, toolCallId: toolCallId) {
            existing.summary = summary
            existing.updatedAt = .now
        } else {
            context.insert(PlanDecisionRecord(
                sessionId: sessionId,
                toolCallId: toolCallId,
                summary: summary
            ))
        }
        save()
    }

    private func planDecisions(sessionId: String) -> [PlanDecisionRecord] {
        let descriptor = FetchDescriptor<PlanDecisionRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func renamePlanDecisions(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        for row in planDecisions(sessionId: oldId) {
            if fetchPlanDecision(sessionId: newId, toolCallId: row.toolCallId) != nil {
                context.delete(row)
            } else {
                row.sessionId = newId
            }
        }
    }

    func deletePlanDecisionRows(sessionId: String) {
        for row in planDecisions(sessionId: sessionId) { context.delete(row) }
    }

    // MARK: - Hook Cards

    func loadHookCards(sessionId: String) -> [HookCardRecord] {
        let descriptor = FetchDescriptor<HookCardRecord>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchHookCard(toolId: String) -> HookCardRecord? {
        var descriptor = FetchDescriptor<HookCardRecord>(
            predicate: #Predicate { $0.toolId == toolId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func upsertHookCard(
        sessionId: String,
        toolId: String,
        toolName: String,
        input: [String: JSONValue],
        result: String?,
        isError: Bool,
        isComplete: Bool
    ) {
        let data = (try? JSONEncoder().encode(input)) ?? Data()
        if let existing = fetchHookCard(toolId: toolId) {
            existing.sessionId = sessionId
            existing.toolName = toolName
            existing.inputData = data
            existing.result = result
            existing.isError = isError
            existing.isComplete = isComplete
            existing.updatedAt = .now
        } else {
            context.insert(HookCardRecord(
                toolId: toolId,
                sessionId: sessionId,
                toolName: toolName,
                inputData: data,
                result: result,
                isError: isError,
                isComplete: isComplete
            ))
        }
        save()
    }

    @discardableResult
    func completeHookCard(toolId: String, result: String, isError: Bool, isComplete: Bool = true) -> Bool {
        guard let row = fetchHookCard(toolId: toolId) else { return false }
        row.result = result
        row.isError = isError
        row.isComplete = isComplete
        row.updatedAt = .now
        save()
        return true
    }

    func finalizeInterruptedHookCards() {
        let descriptor = FetchDescriptor<HookCardRecord>(
            predicate: #Predicate { $0.isComplete == false }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows {
            row.isComplete = true
            row.isError = true
            if (row.result ?? "").isEmpty {
                row.result = "Interrupted — the app closed while this hook was running."
            }
            row.updatedAt = .now
        }
        save()
    }

    func renameHookCards(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        for row in loadHookCards(sessionId: oldId) { row.sessionId = newId }
    }

    func deleteHookCardRows(sessionId: String) {
        for row in loadHookCards(sessionId: sessionId) { context.delete(row) }
    }

    // MARK: - Hook Status (legacy)

    private func fetchHookStatus(sessionId: String) -> HookStatusRecord? {
        var descriptor = FetchDescriptor<HookStatusRecord>(
            predicate: #Predicate { $0.sessionId == sessionId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func finalizeInterruptedHooks() {
        let descriptor = FetchDescriptor<HookStatusRecord>(
            predicate: #Predicate { $0.isComplete == false }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        for row in rows {
            row.isComplete = true
            row.isError = true
            if row.output.isEmpty {
                row.output = "Interrupted — the app closed while this hook was running."
            }
            row.updatedAt = .now
        }
        save()
    }

    @discardableResult
    func finalizeInterruptedCompletionChecks() -> [String] {
        let inProgress = TaskCompletionCheckLabel.inProgress
        let descriptor = FetchDescriptor<ChatThread>(
            predicate: #Predicate { $0.threadLabel == inProgress }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return [] }
        for row in rows {
            row.threadLabel = TaskCompletionCheckLabel.unverified
        }
        save()
        return rows.map(\.id)
    }

    func setThreadLinkage(
        sessionId: String,
        parentThreadId: String?,
        threadLabel: String?,
        skipHooks: Bool
    ) {
        guard let thread = fetch(id: sessionId) else { return }
        thread.parentThreadId = parentThreadId
        thread.threadLabel = threadLabel
        thread.skipHooks = skipHooks
        save()
    }

    func renameHookStatus(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        guard let row = fetchHookStatus(sessionId: oldId) else { return }
        if fetchHookStatus(sessionId: newId) != nil {
            context.delete(row)
        } else {
            row.sessionId = newId
        }
    }

    func deleteHookStatusRow(sessionId: String) {
        guard let row = fetchHookStatus(sessionId: sessionId) else { return }
        context.delete(row)
    }
}
