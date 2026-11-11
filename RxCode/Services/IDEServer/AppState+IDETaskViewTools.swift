import Foundation
import RxCodeCore

extension AppState {
    func handleTaskViews(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        if let project = arguments["project_id"], project.stringValue == nil {
            throw IDEToolError.invalidArguments("project_id must be a project UUID string.")
        }
        let projectId = try taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        await ensureTaskBoardLoaded(for: projectId)
        var board = taskBoard(for: projectId)
        let result = try TaskViewsTool.apply(arguments, to: &board)
        if arguments["operation"]?.stringValue != "list" {
            setTaskBoard(board, for: projectId)
        }
        return jsonTextResult(.object([
            "project_id": .string(projectId.uuidString),
            "default_view_id": .string(board.defaultView.id.uuidString),
            "columns": .array(board.effectiveColumns.map { .object([
                "id": .string($0.id.rawValue), "name": .string($0.name),
            ]) }),
            "views": result,
        ]))
    }
}
