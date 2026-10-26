import Foundation
import RxCodeCore

// MARK: - IDE Polyfill Tools
//
// Handlers for polyfill tools (`ide__set_todos`, `ide__ask_user`) that are only
// exposed to backends lacking the native feature. Dispatched from
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
        threadStore.upsertTodoSnapshot(sessionId: sessionKey, items: parsed)
        todoSnapshotsRevision &+= 1
        return textResult("Recorded \(parsed.count) todo(s).")
    }

    /// Polyfill for backends without a native AskUserQuestion: route the prompt
    /// through the same queue + `QuestionSheetView` and block until answered.
    func handleAskUser(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
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
        let toolInput: [String: JSONValue] = [
            "questions": .array([.object([
                "question": .string(question),
                "multiSelect": .bool(arguments["allow_multiple"]?.boolValue ?? false),
                "options": .array(options),
            ])]),
        ]
        let sessionId = await MainActor.run { resolveCurrentSessionId(sessionKey) }
        guard let payload = await permission.requestAskUserAnswers(
            toolUseId: "ide_ask_user_\(UUID().uuidString)",
            sessionId: sessionId,
            toolInput: toolInput
        ) else {
            return textResult("The user skipped the question without answering. Do not assume an answer — continue without it or ask again in plain text.")
        }
        let answer = payload["answers"]?[question]
        if let values = answer?.arrayValue?.compactMap(\.stringValue) {
            return textResult("User selected: \(values.joined(separator: ", "))")
        }
        if let value = answer?.stringValue {
            return textResult("User answered: \(value)")
        }
        return textResult("The user did not provide an answer.")
    }
}
