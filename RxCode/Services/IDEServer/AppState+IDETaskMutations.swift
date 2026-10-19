import Foundation
import RxCodeCore

/// Task mutations exposed through the IDE MCP server.
extension AppState {
    @MainActor
    func handleUpdateTask(arguments: JSONValue) async throws -> JSONValue {
        await ensureAllTaskBoardsLoaded()
        var task = try parseTaskId(arguments)
        let board = taskBoard(for: task.projectId)
        let fields: Set<String> = ["title", "details", "status", "story_id", "priority", "version",
                                   "milestone", "type_id", "tags", "starts_after_task_ids", "provider", "model"]
        guard let object = arguments.objectValue,
              Set(object.keys).isSubset(of: fields.union(["task_id"])),
              !fields.isDisjoint(with: object.keys) else {
            throw IDEToolError.invalidArguments("Pass at least one supported task field to update.")
        }
        // Build and validate the entire patch before changing board state.
        func string(_ field: String) throws -> String {
            guard let value = arguments[field]?.stringValue else {
                throw IDEToolError.invalidArguments("\(field) must be a string.")
            }
            return value
        }
        func optionalString(_ field: String) throws -> String? {
            if arguments[field] == .null { return nil }
            return try string(field)
        }
        if arguments["provider"] != nil || arguments["model"] != nil {
            guard !isAgentRunning(for: task) else {
                throw IDEToolError.handlerFailed("Cannot change the agent assignment while the task's agent is running.")
            }
            if arguments["provider"] != nil {
                let provider: AgentProvider?
                if let raw = try optionalString("provider") {
                    guard let parsed = AgentProvider(rawValue: raw) else {
                        throw IDEToolError.invalidArguments("provider must be claudeCode, codex, acp, or null.")
                    }
                    provider = parsed
                } else { provider = nil }
                if provider != task.agent.provider {
                    task.agent.model = nil
                    task.agent.effort = nil
                }
                task.agent.provider = provider
                if provider == nil {
                    task.agent.model = nil
                    task.agent.effort = nil
                }
            }
            if arguments["model"] != nil {
                let model = try optionalString("model")
                if let model {
                    guard let provider = task.agent.provider,
                          availableAgentModelSections().contains(where: {
                              $0.provider == provider && $0.models.contains(where: { $0.id == model })
                          }) else {
                        throw IDEToolError.invalidArguments("model must match the selected provider's catalog. Call ide__list_agent_models for supported provider and model ids.")
                    }
                }
                if model != task.agent.model { task.agent.effort = nil }
                task.agent.model = model
            }
        }
        if arguments["title"] != nil {
            let title = try string("title").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw IDEToolError.invalidArguments("title must not be empty.") }
            task.title = title
        }
        if arguments["details"] != nil {
            let details = try string("details")
            guard !task.isDescriptionLocked || details == task.details else {
                throw IDEToolError.invalidArguments("The description cannot change after the task has started. Use ide__run_task with a follow-up prompt instead.")
            }
            task.details = details
        }
        if arguments["status"] != nil {
            let status = TaskStatus(rawValue: try string("status"))
            guard board.effectiveColumns.contains(where: { $0.id == status }) else {
                throw IDEToolError.invalidArguments("status must identify an existing column in the task's project.")
            }
            guard !board.isStatusLocked(task) || board.resolvedStatus(of: task) == status else {
                throw IDEToolError.handlerFailed("The task's running agent owns its status.")
            }
            if task.status != status {
                task.status = status
                task.sortIndex = board.appendSortIndex(for: status)
                task.isQueued = false
            }
        }
        if arguments["story_id"] != nil {
            if let raw = try optionalString("story_id") {
                guard let id = UUID(uuidString: raw), board.story(id: id) != nil else {
                    throw IDEToolError.invalidArguments("story_id must identify a story in the task's project.")
                }
                task.storyId = id
            } else { task.storyId = nil }
        }
        if arguments["priority"] != nil {
            if let raw = try optionalString("priority") {
                guard let priority = TaskPriority(rawValue: raw) else {
                    throw IDEToolError.invalidArguments("priority must be urgent, high, medium, low, or null.")
                }
                task.priority = priority
            } else { task.priority = nil }
        }
        if arguments["version"] != nil { task.version = try optionalString("version") }
        if arguments["milestone"] != nil { task.milestone = try optionalString("milestone") }
        if arguments["type_id"] != nil {
            if let raw = try optionalString("type_id") {
                guard let id = UUID(uuidString: raw), board.effectiveTypes.contains(where: { $0.id == id }) else {
                    throw IDEToolError.invalidArguments("type_id must identify an item type in the task's project.")
                }
                task.typeId = id
            } else { task.typeId = nil }
        }
        for field in ["tags", "starts_after_task_ids"] where arguments[field] != nil {
            guard let entries = arguments[field]?.arrayValue,
                  entries.allSatisfy({ $0.stringValue != nil }) else {
                throw IDEToolError.invalidArguments("\(field) must be an array of strings.")
            }
            let values = entries.compactMap(\.stringValue)
            if field == "tags" {
                task.tags = values
            } else {
                task.parentTaskIds = try values.map { raw in
                    guard let id = UUID(uuidString: raw), self.task(id: id) != nil,
                          canLinkTask(task.id, to: id) else {
                        throw IDEToolError.invalidArguments("Prerequisites must be existing tasks and cannot create a dependency cycle.")
                    }
                    return id
                }
            }
        }
        upsertTask(task)
        return jsonTextResult(.object(taskJSON(self.task(id: task.id) ?? task)))
    }

    @MainActor
    func handleDeleteTask(arguments: JSONValue) async throws -> JSONValue {
        // Load every board so cross-project prerequisite links are removed too.
        await ensureAllTaskBoardsLoaded()
        let task = try parseTaskId(arguments)
        guard !isAgentRunning(for: task) else {
            throw IDEToolError.handlerFailed("Cannot delete a task while its agent is running.")
        }
        deleteTask(task)
        return jsonTextResult(.object([
            "id": .string(task.id.uuidString),
            "project_id": .string(task.projectId.uuidString),
            "deleted": .bool(true),
        ]))
    }

}
