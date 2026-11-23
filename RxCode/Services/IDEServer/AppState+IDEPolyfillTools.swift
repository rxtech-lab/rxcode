import Foundation
import RxCodeCore

// MARK: - IDE Polyfill Tools
//
// Handlers for the todo polyfill and the always-available IDE question tool. Dispatched from
// `ideHandleToolCall` in AppState+IDEToolHandling.swift.

extension AppState {
    @MainActor
    func handleSetTodos(arguments: JSONValue, sessionKey: String) throws -> JSONValue {
        guard let todosArray = arguments["todos"]?.arrayValue else {
            throw IDEToolError.invalidArguments("missing 'todos' array")
        }
        let parsed: [TodoItem] = todosArray.enumerated().compactMap { idx, entry -> TodoItem? in
            guard
                let dict = entry.objectValue,
                let content = dict["content"]?.stringValue,
                let statusRaw = dict["status"]?.stringValue,
                let status = TodoItem.Status(rawValue: statusRaw)
            else { return nil }
            let activeForm = dict["activeForm"]?.stringValue ?? content
            return TodoItem(id: idx, content: content, activeForm: activeForm, status: status)
        }
        let sessionId = resolveCurrentSessionId(sessionKey)
        recordTodoSnapshot(parsed, forSessionId: sessionId)
        broadcastMobileSessionStatus(sessionID: sessionId)
        return textResult("Recorded \(parsed.count) todo(s).")
    }

    /// Available to every backend, regardless of agent mode: route the prompt
    /// through the same queue + `QuestionSheetView` and block until answered.
    func handleAskUser(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let question = try IDEUserQuestion(arguments)
        let response = await question.ask(via: permission, sessionID: resolveCurrentSessionId(sessionKey))
        return textResult(response.result)
    }
}

nonisolated struct IDEUserQuestion {
    typealias Response = (answer: String?, result: String)
    let question: String
    let toolInput: [String: JSONValue]

    init(_ arguments: JSONValue) throws {
        guard let question = arguments["question"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty
        else {
            throw IDEToolError.invalidArguments("missing 'question'")
        }
        let options: [JSONValue] = (arguments["options"]?.arrayValue ?? []).compactMap { entry in
            if let label = entry.stringValue, !label.isEmpty {
                return .object(["label": .string(label)])
            }
            if let obj = entry.objectValue, obj["label"]?.stringValue?.isEmpty == false {
                return entry
            }
            return nil
        }
        guard !options.isEmpty else {
            throw IDEToolError.invalidArguments("'options' must contain at least one option")
        }
        self.question = question
        toolInput = [
            "questions": .array([.object([
                "question": .string(question),
                "multiSelect": .bool(arguments["allow_multiple"]?.boolValue ?? false),
                "options": .array(options),
            ])]),
        ]
    }

    func ask(via permission: PermissionServer, sessionID: String, toolUseID: String = "ide_ask_user_\(UUID())") async
        -> Response {
        guard let payload = await permission.requestAskUserAnswers(
            toolUseId: toolUseID,
            sessionId: sessionID,
            toolInput: toolInput
        ) else {
            return (nil, "The user skipped the question. Continue without assuming an answer.")
        }
        let answer = payload["answers"]?[question]
        if let values = answer?.arrayValue?.compactMap(\.stringValue) {
            let answer = values.joined(separator: ", ")
            return (answer, "User selected: \(answer)")
        }
        if let value = answer?.stringValue {
            return (value, "User answered: \(value)")
        }
        return (nil, "The user did not provide an answer.")
    }
}
