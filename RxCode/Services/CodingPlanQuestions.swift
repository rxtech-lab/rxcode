import Foundation
import RxCodeCore

/// One speaker's question tool. Its calls belong to the plan thread even though
/// every backend turn has a fresh session key.
@MainActor
final class CodingPlanQuestions: IDEToolHandling {
    private static let idPrefix = "coding-plan-question-"
    private weak var appState: AppState?
    private weak var room: CodingPlanRoom?
    private let runID: UUID
    private var pending: [String: Task<IDEUserQuestion.Response, Error>] = [:]
    private var lastResolvedAt: ContinuousClock.Instant?
    private var closed = false

    init(appState: AppState, room: CodingPlanRoom, runID: UUID) {
        self.appState = appState
        self.room = room
        self.runID = runID
    }

    static func owns(_ toolUseID: String) -> Bool { toolUseID.hasPrefix(idPrefix) }
    func isPending(_ toolUseID: String) -> Bool { pending[toolUseID] != nil }

    func ideAvailableTools(forSession sessionKey: String) async -> [IDETool] { [IDEToolRegistry.askUser] }

    func ideHandleToolCall(name: String, arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        guard name == IDEToolRegistry.askUser.name else { throw IDEToolError.unknownTool(name) }
        return .string(try await ask(arguments))
    }

    func ask(_ arguments: JSONValue) async throws -> String {
        let question = try IDEUserQuestion(arguments)
        guard !closed, let room, room.runID == runID, let appState else { throw CancellationError() }
        let id = Self.idPrefix + UUID().uuidString
        let response = Task {
            defer {
                pending.removeValue(forKey: id)
                lastResolvedAt = .now
                if appState.mobilePendingRequests[id] != nil { appState.clearAutoResolvedPermissions([id]) }
            }
            let response = await question.ask(via: appState.permission, sessionID: room.plan.id.uuidString, toolUseID: id)
            try Task.checkCancellation()
            guard room.runID == runID, !closed else { throw CancellationError() }
            if let answer = response.answer {
                var updated = room.plan
                updated.contributions.append(.init(role: "You", model: nil, text: answer, question: question.question))
                try appState.threadStore.saveCodingPlan(updated)
                room.plan = updated
            }
            return response
        }
        pending[id] = response
        return try await withTaskCancellationHandler {
            try await response.value.result
        } onCancel: {
            response.cancel()
        }
    }

    func inactivityDeadline(streamDeadline: ContinuousClock.Instant, timeout: Duration) -> ContinuousClock.Instant {
        if !pending.isEmpty { return .now.advanced(by: timeout) }
        return max(streamDeadline, lastResolvedAt?.advanced(by: timeout) ?? streamDeadline)
    }

    /// Some external clients finish after their own MCP timeout. If an answer
    /// arrives after that, retry this speaker with the saved clarification.
    func receivedAnswerAfterTurn() async throws -> Bool {
        let outstanding = Array(pending.values)
        var answered = false
        for task in outstanding {
            if try await task.value.answer != nil { answered = true }
        }
        return answered
    }

    func close() {
        closed = true
        let ids = Array(pending.keys)
        for task in pending.values { task.cancel() }
        pending.removeAll()
        appState?.clearAutoResolvedPermissions(ids)
    }
}
