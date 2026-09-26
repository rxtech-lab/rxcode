import Foundation
import os
import RxCodeCore

// MARK: - IDEToolHandling Conformance
//
// AppState exposes IDE-side tools to MCP-capable agents through the bridge
// `IDEMCPServer`. The conformance lives in its own file so AppState.swift
// stays focused on chat/session state.
//
// Per-session capability gating:
//   • Polyfill tools (`ide__set_todos`, `ide__ask_user`) are filtered out
//     for backends that natively support the feature — see
//     `IDEToolRegistry.tools(for:)`.
//   • IDE-only tools (`ide__get_running_jobs` etc.) always appear so any
//     agent can introspect editor state.
//
// `sessionKey` is the AppState session key the agent is bound to. The
// listener allocates one port per session, so this is unambiguous.

extension AppState: IDEToolHandling {
    public func ideAvailableTools(forSession sessionKey: String) async -> [IDETool] {
        let provider = await MainActor.run { sessionStates[sessionKey]?.agentProvider } ?? .acp
        let caps = await backend(for: provider).capabilities(for: sessionKey)
        return IDEToolRegistry.tools(for: caps)
    }

    public func ideHandleToolCall(
        name: String,
        arguments: JSONValue,
        sessionKey: String
    ) async throws -> JSONValue {
        switch name {
        case "ide__set_todos":
            return try await handleSetTodos(arguments: arguments, sessionKey: sessionKey)
        case "ide__get_running_jobs":
            return await handleGetRunningJobs()
        case "ide__get_job_output":
            throw IDEToolError.notSupported("ide__get_job_output is not yet implemented")
        case "ide__get_projects":
            return handleGetProjects()
        case "ide__get_stories":
            return try await handleGetStories(arguments: arguments, sessionKey: sessionKey)
        case "ide__create_story":
            return try await handleCreateStory(arguments: arguments, sessionKey: sessionKey)
        case "ide__create_task":
            return try await handleCreateTask(arguments: arguments, sessionKey: sessionKey)
        case "ide__link_story":
            return try await handleLinkStory(arguments: arguments, sessionKey: sessionKey)
        case "ide__get_tasks":
            return try await handleGetTasks(arguments: arguments, sessionKey: sessionKey)
        case "ide__run_task":
            return try await handleRunTask(arguments: arguments)
        case "ide__get_task_status":
            return try await handleGetTaskStatus(arguments: arguments)
        case "ide__get_threads":
            return await handleGetThreads(arguments: arguments)
        case "ide__get_thread_messages", "ide__get_thread_detail":
            return try await handleGetThreadMessages(arguments: arguments)
        case "ide__memory_search":
            return try await handleMemorySearch(arguments: arguments)
        case "ide__memory_add":
            return try await handleMemoryAdd(arguments: arguments)
        case "ide__memory_update":
            return try await handleMemoryUpdate(arguments: arguments)
        case "ide__memory_delete":
            return try await handleMemoryDelete(arguments: arguments)
        case "ide__send_to_thread":
            return try await handleSendToThread(arguments: arguments)
        case "ide__get_usage":
            return await handleGetUsage()
        case "ide__search_docs":
            return try await handleSearchDocs(arguments: arguments)
        case "ide__setup_docs_secret":
            return try await handleSetupDocsSecret(arguments: arguments, sessionKey: sessionKey)
        case "ide__setup_release":
            return try await handleSetupRelease(arguments: arguments, sessionKey: sessionKey)
        case "ide__ask_user":
            throw IDEToolError.notSupported("ide__ask_user polyfill not implemented yet — surface the question as plain assistant text instead.")
        default:
            throw IDEToolError.unknownTool(name)
        }
    }

    // MARK: - Handlers

    @MainActor
    private func handleSetTodos(arguments: JSONValue, sessionKey: String) throws -> JSONValue {
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

    @MainActor
    private func handleGetRunningJobs() -> JSONValue {
        let entries: [JSONValue] = runService.activeTasks.map { task in
            .object([
                "id": .string(task.id.uuidString),
                "profile_name": .string(task.profile.name),
                "project_id": .string(task.project.id.uuidString),
                "started_at": .string(ISO8601DateFormatter().string(from: task.startedAt)),
                "status": .string(String(describing: task.status)),
            ])
        }
        return jsonTextResult(.array(entries))
    }

    @MainActor
    private func handleGetProjects() -> JSONValue {
        let entries: [JSONValue] = projects.map { p in
            .object([
                "id": .string(p.id.uuidString),
                "name": .string(p.name),
                "path": .string(p.path),
                "github_repo": p.gitHubRepo.map { .string($0) } ?? .null,
                "last_session_id": p.lastSessionId.map { .string($0) } ?? .null,
                "last_agent_provider": p.lastAgentProvider.map { .string($0.rawValue) } ?? .null,
                "last_model": p.lastModel.map { .string($0) } ?? .null,
            ])
        }
        return jsonTextResult(.array(entries))
    }

    @MainActor
    private func taskToolProjectId(arguments: JSONValue, sessionKey: String) throws -> UUID {
        let explicit = try parseOptionalProjectId(arguments["project_id"]?.stringValue)
        guard let id = explicit ?? threadStore.fetch(id: sessionKey)?.projectId
                ?? allSessionSummaries.first(where: { $0.id == resolveCurrentSessionId(sessionKey) })?.projectId,
              projects.contains(where: { $0.id == id })
        else {
            throw IDEToolError.invalidArguments("Pass a valid project_id or call from a saved project chat.")
        }
        return id
    }

    @MainActor
    private func handleGetStories(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let projectId = try taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        await ensureTaskBoardLoaded(for: projectId)
        let board = taskBoard(for: projectId)
        let rollups = board.storyRollups()
        return jsonTextResult(.array(board.stories.map { story in
            var obj = storyJSON(story)
            if let rollup = rollups[story.id] {
                obj["status"] = .string(rollup.status.rawValue)
                obj["tasks_done"] = .number(Double(rollup.progress.done))
                obj["tasks_total"] = .number(Double(rollup.progress.total))
            }
            return .object(obj)
        }))
    }

    private func storyJSON(_ story: ProjectStory) -> [String: JSONValue] {
        [
            "id": .string(story.id.uuidString),
            "project_id": .string(story.projectId.uuidString),
            "title": .string(story.title),
            "details": .string(story.details),
            "linked_project_ids": .array(story.linkedProjectIds.map { .string($0.uuidString) }),
        ]
    }

    private func parseProjectIdList(_ value: JSONValue?, field: String) throws -> [UUID] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw IDEToolError.invalidArguments("\(field) must be an array of project UUIDs.")
        }
        return try array.map { entry in
            guard let raw = entry.stringValue, let id = UUID(uuidString: raw),
                  projects.contains(where: { $0.id == id })
            else {
                throw IDEToolError.invalidArguments("\(field) contains an unknown project id. Call ide__get_projects first.")
            }
            return id
        }
    }

    @MainActor
    private func handleCreateStory(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let projectId = try taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        guard let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw IDEToolError.invalidArguments("A nonempty title is required.")
        }
        let linked = try parseProjectIdList(arguments["linked_project_ids"], field: "linked_project_ids")
        await ensureTaskBoardLoaded(for: projectId)
        let story = ProjectStory(projectId: projectId, title: title, details: arguments["details"]?.stringValue ?? "")
        upsertStory(story)
        let result = linked.isEmpty
            ? story
            : await linkStory(story.id, in: projectId, to: linked) ?? story
        return jsonTextResult(.object(storyJSON(result)))
    }

    @MainActor
    private func handleLinkStory(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        guard let raw = arguments["story_id"]?.stringValue, let storyId = UUID(uuidString: raw) else {
            throw IDEToolError.invalidArguments("A valid story_id is required.")
        }
        let link = try parseProjectIdList(arguments["link_project_ids"], field: "link_project_ids")
        let unlink = try parseProjectIdList(arguments["unlink_project_ids"], field: "unlink_project_ids")
        guard !link.isEmpty || !unlink.isEmpty else {
            throw IDEToolError.invalidArguments("Pass link_project_ids or unlink_project_ids.")
        }
        guard Set(link).isDisjoint(with: unlink) else {
            throw IDEToolError.invalidArguments("A project cannot be both linked and unlinked.")
        }
        await ensureAllTaskBoardsLoaded()
        // The story's own board: the explicit or current project when it holds
        // the story, otherwise any board that does.
        let preferred = try? taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        guard let projectId = [preferred].compactMap({ $0 }).first(where: { taskBoard(for: $0).story(id: storyId) != nil })
                ?? taskBoards.first(where: { $0.value.story(id: storyId) != nil })?.key
        else {
            throw IDEToolError.invalidArguments("story_id must identify an existing story.")
        }

        var story = taskBoard(for: projectId).story(id: storyId)
        if !link.isEmpty {
            story = await linkStory(storyId, in: projectId, to: link)
        }
        if !unlink.isEmpty {
            // Unlinking the anchor board itself still leaves the story on the
            // remaining boards, so read the result back from one of those.
            story = unlinkStory(storyId, in: projectId, from: unlink)
        }
        guard let story else {
            return textResult("Story \(storyId.uuidString) is no longer on any project board.")
        }
        return jsonTextResult(.object(storyJSON(story)))
    }

    @MainActor
    private func handleCreateTask(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let projectId = try taskToolProjectId(arguments: arguments, sessionKey: sessionKey)
        let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let details = arguments["details"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty || !details.isEmpty else {
            throw IDEToolError.invalidArguments("A nonempty title or details is required.")
        }
        await ensureTaskBoardLoaded(for: projectId)
        let storyId: UUID?
        if let raw = arguments["story_id"]?.stringValue {
            guard let id = UUID(uuidString: raw), taskBoard(for: projectId).story(id: id) != nil else {
                throw IDEToolError.invalidArguments("story_id must identify a story in this project.")
            }
            storyId = id
        } else {
            storyId = nil
        }
        // A task's own chat identifies its card even when a follow-up describes
        // the work differently. Content matching also covers a separate chat
        // recording the same request again.
        let resolvedSession = resolveCurrentSessionId(sessionKey)
        let threadTask = taskBoard(for: projectId).tasks.first { task in
            task.sessionKey.map { resolveCurrentSessionId($0) == resolvedSession } ?? false
        }
        if let existing = threadTask ?? matchingTask(projectId: projectId, title: title, details: details, storyId: storyId) {
            return jsonTextResult(.object([
                "id": .string(existing.id.uuidString),
                "project_id": .string(projectId.uuidString),
                "story_id": existing.storyId.map { .string($0.uuidString) } ?? .null,
                "title": .string(existing.title),
                "already_exists": .bool(true),
            ]))
        }
        let task: ProjectTask
        if title.isEmpty {
            task = quickAddTask(text: details, projectId: projectId, storyId: storyId, sourceSessionKey: sessionKey)
        } else {
            let story = taskBoard(for: projectId).story(id: storyId)
            task = ProjectTask(
                projectId: projectId,
                storyId: storyId,
                title: title,
                details: details,
                status: taskBoard(for: projectId).firstColumn.id,
                version: story?.version,
                milestone: story?.milestone,
                agent: defaultTaskAgent(),
                sourceSessionKey: sessionKey
            )
            upsertTask(task)
        }
        return jsonTextResult(.object([
            "id": .string(task.id.uuidString),
            "project_id": .string(projectId.uuidString),
            "story_id": storyId.map { .string($0.uuidString) } ?? .null,
            "title": .string(task.title),
        ]))
    }

    private func parseTaskId(_ arguments: JSONValue) throws -> ProjectTask {
        guard let raw = arguments["task_id"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw IDEToolError.invalidArguments("A valid task_id is required.")
        }
        guard let task = task(id: id) else {
            throw IDEToolError.invalidArguments("No task with id \(raw). Call ide__get_tasks first.")
        }
        return task
    }

    private func taskJSON(_ task: ProjectTask) -> [String: JSONValue] {
        let board = taskBoard(for: task.projectId)
        let column = board.column(for: task.status)
        return [
            "id": .string(task.id.uuidString),
            "project_id": .string(task.projectId.uuidString),
            "project_name": projects.first(where: { $0.id == task.projectId }).map { .string($0.name) } ?? .null,
            "story_id": task.storyId.map { .string($0.uuidString) } ?? .null,
            "parent_task_id": task.parentTaskId.map { .string($0.uuidString) } ?? .null,
            "title": .string(task.title),
            "status": .string(column.id.rawValue),
            "column": .string(column.name),
            "is_done": .bool(column.countsAsDone),
            "is_running": .bool(isAgentRunning(for: task)),
            "thread_id": chatSessionId(for: task).map { .string($0) } ?? .null,
            "agent_provider": task.agent.provider.map { .string($0.rawValue) } ?? .null,
            "agent_model": task.agent.model.map { .string($0) } ?? .null,
            "attention_reason": task.attentionReason.map { .string($0) } ?? .null,
            "updated_at": .string(ISO8601DateFormatter().string(from: task.updatedAt)),
        ]
    }

    @MainActor
    private func handleGetTasks(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        let storyId: UUID?
        if let raw = arguments["story_id"]?.stringValue {
            guard let id = UUID(uuidString: raw) else {
                throw IDEToolError.invalidArguments("story_id must be a UUID.")
            }
            storyId = id
        } else {
            storyId = nil
        }
        let projectIds: [UUID]
        if storyId != nil, try parseOptionalProjectId(arguments["project_id"]?.stringValue) == nil {
            // A linked story spans several boards; read all of them.
            await ensureAllTaskBoardsLoaded()
            projectIds = Array(taskBoards.keys)
        } else {
            projectIds = [try taskToolProjectId(arguments: arguments, sessionKey: sessionKey)]
        }
        let status = arguments["status"]?.stringValue.map { TaskStatus(rawValue: $0) }

        var tasks: [ProjectTask] = []
        for projectId in projectIds {
            await ensureTaskBoardLoaded(for: projectId)
            let board = taskBoard(for: projectId)
            tasks += board.tasks.filter { task in
                (storyId == nil || task.storyId == storyId)
                    && (status == nil || board.resolvedStatus(of: task) == status)
            }
        }
        tasks.sort { ($0.projectId.uuidString, $0.sortIndex) < ($1.projectId.uuidString, $1.sortIndex) }
        return jsonTextResult(.array(tasks.map { .object(taskJSON($0)) }))
    }

    @MainActor
    private func handleRunTask(arguments: JSONValue) async throws -> JSONValue {
        var task = try parseTaskId(arguments)
        if isAgentRunning(for: task) {
            throw IDEToolError.handlerFailed("The task's agent is already running. Poll ide__get_task_status instead.")
        }
        let board = taskBoard(for: task.projectId)

        if let prompt = arguments["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            guard chatSessionId(for: task) != nil else {
                throw IDEToolError.invalidArguments("prompt needs a task that already has a thread. Omit prompt to start its first run.")
            }
            guard await sendTaskFollowUp(task, text: prompt) else {
                throw IDEToolError.handlerFailed("Could not send the follow-up to the task's thread.")
            }
            return jsonTextResult(.object(taskJSON(self.task(id: task.id) ?? task)))
        }

        guard let chatColumn = board.firstChatColumn else {
            throw IDEToolError.handlerFailed("This project's board has no column that starts a chat.")
        }
        if board.isStatusLocked(task) {
            throw IDEToolError.handlerFailed("The task is owned by its running agent.")
        }

        let providerOverride: AgentProvider?
        if let raw = arguments["provider"]?.stringValue {
            guard let provider = AgentProvider(rawValue: raw) else {
                throw IDEToolError.invalidArguments("provider must be one of: \(AgentProvider.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            providerOverride = provider
        } else {
            providerOverride = nil
        }
        let modelOverride = arguments["model"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if providerOverride != nil || !(modelOverride ?? "").isEmpty {
            if let providerOverride, providerOverride != task.agent.provider {
                task.agent.model = nil
                task.agent.effort = nil
            }
            task.agent.provider = providerOverride ?? task.agent.provider
            if let modelOverride, !modelOverride.isEmpty { task.agent.model = modelOverride }
        }
        if !task.agent.isAssigned {
            let fallback = defaultTaskAgent()
            task.agent.provider = fallback.provider
            task.agent.model = fallback.model
        }
        guard task.agent.isAssigned else {
            throw IDEToolError.handlerFailed("No agent is assigned to the task and no default task agent is configured.")
        }

        if board.resolvedStatus(of: task) == chatColumn.id {
            // Already sitting in the chat column without a live run (e.g. a
            // released run): moving it there again would not dispatch.
            upsertTask(task)
            Task { await startTask(task) }
        } else {
            upsertTask(task)
            moveTask(self.task(id: task.id) ?? task, to: chatColumn.id)
        }
        var result = taskJSON(self.task(id: task.id) ?? task)
        result["dispatched"] = .bool(true)
        return jsonTextResult(.object(result))
    }

    @MainActor
    private func handleGetTaskStatus(arguments: JSONValue) async throws -> JSONValue {
        let task = try parseTaskId(arguments)
        var result = taskJSON(task)
        let limit = max(0, min(Int(arguments["message_limit"]?.numberValue ?? 5), 50))
        if limit > 0, let messages = await taskRunMessages(for: task) {
            let iso = ISO8601DateFormatter()
            result["messages"] = .array(messages.suffix(limit).compactMap { msg in
                let text = msg.blocks.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
                guard !text.isEmpty else { return nil }
                return .object([
                    "role": .string(msg.role.rawValue),
                    "text": .string(text),
                    "timestamp": .string(iso.string(from: msg.timestamp)),
                ])
            })
        }
        return jsonTextResult(.object(result))
    }

    @MainActor
    private func handleMemorySearch(arguments: JSONValue) async throws -> JSONValue {
        guard let query = arguments["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("missing 'query'")
        }
        let projectId = try parseOptionalProjectId(arguments["project_id"]?.stringValue)
        let requestedLimit = Int(arguments["limit"]?.numberValue ?? 20)
        let limit = max(1, min(requestedLimit, 100))
        let hits = await searchMemoryItems(query: query, projectId: projectId, limit: limit)
        return jsonTextResult(.array(hits.map { memoryJSON(item: $0.item, score: $0.score) }))
    }

    @MainActor
    private func handleMemoryAdd(arguments: JSONValue) async throws -> JSONValue {
        guard let content = arguments["content"]?.stringValue, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("missing 'content'")
        }
        let scope = arguments["scope"]?.stringValue ?? "project"
        let kind = arguments["kind"]?.stringValue ?? "fact"
        let projectId = try parseOptionalProjectId(arguments["project_id"]?.stringValue)
        guard let item = await addMemoryItem(
            content: content,
            projectId: projectId,
            kind: kind,
            scope: scope
        ) else {
            throw IDEToolError.handlerFailed("Memory could not be embedded or stored.")
        }
        return jsonTextResult(memoryJSON(item: item, score: nil))
    }

    @MainActor
    private func handleMemoryUpdate(arguments: JSONValue) async throws -> JSONValue {
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            throw IDEToolError.invalidArguments("missing 'id'")
        }
        guard let content = arguments["content"]?.stringValue, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("missing 'content'")
        }
        let scope = arguments["scope"]?.stringValue ?? "project"
        let projectId = try parseOptionalProjectId(arguments["project_id"]?.stringValue)
        guard let item = await updateMemoryItem(
            id: id,
            content: content,
            projectId: projectId,
            kind: arguments["kind"]?.stringValue ?? "fact",
            scope: scope
        ) else {
            throw IDEToolError.handlerFailed("Memory \(id) could not be updated.")
        }
        return jsonTextResult(memoryJSON(item: item, score: nil))
    }

    @MainActor
    private func handleMemoryDelete(arguments: JSONValue) async throws -> JSONValue {
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            throw IDEToolError.invalidArguments("missing 'id'")
        }
        await deleteMemoryItem(id: id)
        return textResult("Deleted memory \(id).")
    }

    @MainActor
    private func handleSendToThread(arguments: JSONValue) async throws -> JSONValue {
        guard let prompt = arguments["prompt"]?.stringValue, !prompt.isEmpty else {
            throw IDEToolError.invalidArguments("missing 'prompt'")
        }
        let threadId = arguments["thread_id"]?.stringValue
        let projectIdStr = arguments["project_id"]?.stringValue
        if threadId != nil && projectIdStr != nil {
            throw IDEToolError.invalidArguments("pass either 'thread_id' or 'project_id', not both")
        }
        if threadId == nil && projectIdStr == nil {
            throw IDEToolError.invalidArguments("one of 'thread_id' or 'project_id' is required")
        }
        let projectId: UUID? = projectIdStr.flatMap(UUID.init(uuidString:))
        if let projectIdStr, projectId == nil {
            throw IDEToolError.invalidArguments("'project_id' is not a valid UUID: \(projectIdStr)")
        }

        let agentProvider: AgentProvider? = arguments["agent_provider"]?.stringValue
            .flatMap(AgentProvider.init(rawValue:))
        let model = arguments["model"]?.stringValue
        let effort = arguments["effort"]?.stringValue
        let permissionMode: PermissionMode? = arguments["permission_mode"]?.stringValue
            .flatMap(PermissionMode.init(rawValue:))
        let waitForResponse = arguments["wait_for_response"]?.boolValue ?? true
        let requestedTimeout = arguments["timeout_seconds"]?.numberValue ?? 20
        let timeoutSeconds = max(1, min(requestedTimeout, 20))
        logger.info("[IDE_SEND_THREAD] ide__send_to_thread start projectId=\(projectId?.uuidString ?? "<nil>", privacy: .public) threadId=\(threadId ?? "<nil>", privacy: .public) wait=\(waitForResponse, privacy: .public) requestedTimeout=\(String(format: "%.1f", requestedTimeout), privacy: .public)s effectiveTimeout=\(String(format: "%.1f", timeoutSeconds), privacy: .public)s provider=\(agentProvider?.rawValue ?? "<default>", privacy: .public) model=\(model ?? "<default>", privacy: .public) promptChars=\(prompt.count, privacy: .public)")

        do {
            let result = try await sendCrossProject(
                projectId: projectId,
                threadId: threadId,
                prompt: prompt,
                agentProvider: agentProvider,
                model: model,
                effort: effort,
                permissionMode: permissionMode,
                waitForResponse: waitForResponse,
                timeoutSeconds: timeoutSeconds,
                includeIDEMCP: false
            )
            logger.info("[IDE_SEND_THREAD] ide__send_to_thread result thread=\(result.threadId, privacy: .public) project=\(result.projectId.uuidString, privacy: .public) done=\(result.done, privacy: .public) error=\(result.error ?? "<nil>", privacy: .public) assistantChars=\(result.assistantText.count, privacy: .public)")
            var obj: [String: JSONValue] = [
                "thread_id": .string(result.threadId),
                "project_id": .string(result.projectId.uuidString),
                "done": .bool(result.done),
                "assistant_text": .string(result.assistantText),
            ]
            if let error = result.error {
                obj["error"] = .string(error)
            }
            return jsonTextResult(.object(obj))
        } catch let error as CrossProjectSendError {
            logger.error("[IDE_SEND_THREAD] ide__send_to_thread failed: \(error.localizedDescription, privacy: .public)")
            throw IDEToolError.handlerFailed(error.localizedDescription)
        } catch {
            logger.error("[IDE_SEND_THREAD] ide__send_to_thread failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func parseOptionalProjectId(_ raw: String?) throws -> UUID? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let id = UUID(uuidString: raw) else {
            throw IDEToolError.invalidArguments("'project_id' is not a valid UUID: \(raw)")
        }
        return id
    }

    private func memoryJSON(item: MemoryItem, score: Float?) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(item.id),
            "content": .string(item.content),
            "kind": .string(item.kind),
            "scope": .string(item.scope),
            "created_at": .string(ISO8601DateFormatter().string(from: item.createdAt)),
            "updated_at": .string(ISO8601DateFormatter().string(from: item.updatedAt)),
            "project_id": item.projectId.map { .string($0.uuidString) } ?? .null,
            "session_id": item.sessionId.map { .string($0) } ?? .null,
        ]
        if let sourceMessageId = item.sourceMessageId {
            obj["source_message_id"] = .string(sourceMessageId.uuidString)
        }
        if let lastUsedAt = item.lastUsedAt {
            obj["last_used_at"] = .string(ISO8601DateFormatter().string(from: lastUsedAt))
        }
        if let score {
            obj["score"] = .number(Double(score))
        }
        return .object(obj)
    }

    @MainActor
    private func handleSearchDocs(arguments: JSONValue) async throws -> JSONValue {
        guard let query = arguments["query"]?.stringValue,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("missing 'query'")
        }
        let repo = arguments["repository"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedLimit = Int(arguments["limit"]?.numberValue ?? 10)
        let limit = max(1, min(requestedLimit, 50))
        do {
            let hits = try await docs.search(query: query, repo: (repo?.isEmpty == false) ? repo : nil, limit: limit)
            let entries: [JSONValue] = hits.map { hit in
                var obj: [String: JSONValue] = ["doc_id": .string(hit.docId)]
                if let repository = hit.repository { obj["repository"] = .string(repository) }
                if let snippet = hit.snippet { obj["snippet"] = .string(snippet) }
                if let score = hit.score { obj["score"] = .number(score) }
                if let link = hit.originalLink { obj["original_link"] = .string(link) }
                return .object(obj)
            }
            return jsonTextResult(.array(entries))
        } catch {
            throw IDEToolError.handlerFailed(error.localizedDescription)
        }
    }

    @MainActor
    private func handleSetupDocsSecret(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        // Prefer an explicit `owner/repo`; otherwise fall back to the repo linked
        // to the calling session's project.
        let explicit = arguments["repository"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo: String
        if let explicit, !explicit.isEmpty {
            repo = explicit
        } else if let thread = threadStore.fetch(id: sessionKey),
                  let linked = projects.first(where: { $0.id == thread.projectId })?.gitHubRepo,
                  !linked.isEmpty {
            repo = linked
        } else {
            throw IDEToolError.invalidArguments(
                "No 'repository' given and the current project has no linked GitHub repo. Pass repository as 'owner/repo'."
            )
        }
        // The install endpoint 404s on unregistered repos, so register first if
        // needed (these throw IDEToolError with their own messages — keep them
        // outside the catch below so they aren't re-wrapped).
        let registered = try await ensureDocsRepoRegistered(repo)
        do {
            let result = try await docs.installGithubSecret(repoId: repo)
            return jsonTextResult(.object([
                "installed": .bool(true),
                "registered": .bool(registered),
                "secret_name": .string(result.secretName),
                "repository": .string(result.repositoryFullName),
            ]))
        } catch {
            throw IDEToolError.handlerFailed(error.localizedDescription)
        }
    }

    /// Ensures `repo` (an `owner/repo`) is registered with the docs service,
    /// registering it if not. Returns true when it had to register it. Throws a
    /// descriptive `IDEToolError` when the repo isn't accessible to the GitHub
    /// App (so it can't be registered).
    @MainActor
    private func ensureDocsRepoRegistered(_ repo: String) async throws -> Bool {
        if let status = try? await docs.statuses(forRepos: [repo]).first, status.hasDocs {
            return false
        }
        guard let managed = try await findManagedRepo(fullName: repo) else {
            throw IDEToolError.handlerFailed(
                "\(repo) isn't set up for docs and isn't accessible to the RxLab GitHub App. Install the GitHub App on this repository, then retry."
            )
        }
        _ = try await docs.addRepository(
            AddDocsRepoBody(
                installationId: managed.installationId,
                repositoryId: managed.id,
                repositoryFullName: managed.fullName
            )
        )
        return true
    }

    @MainActor
    private func handleSetupRelease(arguments: JSONValue, sessionKey: String) async throws -> JSONValue {
        // Prefer an explicit `owner/repo`; otherwise fall back to the repo linked
        // to the calling session's project.
        let explicit = arguments["repository"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repo: String
        if let explicit, !explicit.isEmpty {
            repo = explicit
        } else if let thread = threadStore.fetch(id: sessionKey),
                  let linked = projects.first(where: { $0.id == thread.projectId })?.gitHubRepo,
                  !linked.isEmpty {
            repo = linked
        } else {
            throw IDEToolError.invalidArguments(
                "No 'repository' given and the current project has no linked GitHub repo. Pass repository as 'owner/repo'."
            )
        }
        // Register (and scan workflows) first if needed; throws a descriptive
        // IDEToolError when the repo isn't accessible to the GitHub App.
        let registered = try await ensureReleaseRepoRegistered(repo)

        // The RELEASE_TOKEN is user-supplied — only install when provided.
        let token = arguments["release_token"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else {
            return jsonTextResult(.object([
                "registered": .bool(registered),
                "secret_installed": .bool(false),
                "repository": .string(repo),
                "note": .string("Repository registered and workflows scanned. No release_token was provided, so RELEASE_TOKEN was not installed — ask the user for a GitHub token with contents:write and call again with release_token to finish setup."),
            ]))
        }
        do {
            let result = try await release.installReleaseToken(repoId: repo, value: token)
            return jsonTextResult(.object([
                "registered": .bool(registered),
                "secret_installed": .bool(true),
                "secret_name": .string(result.secretName),
                "repository": .string(result.repositoryFullName),
            ]))
        } catch {
            throw IDEToolError.handlerFailed(error.localizedDescription)
        }
    }

    /// Ensures `repo` (an `owner/repo`) is registered with the release service,
    /// registering it if not. Returns true when it had to register it. Throws a
    /// descriptive `IDEToolError` when the repo isn't accessible to the GitHub
    /// App (so it can't be registered).
    @MainActor
    private func ensureReleaseRepoRegistered(_ repo: String) async throws -> Bool {
        if let status = try? await release.statuses(forRepos: [repo]).first, status.isManaged {
            return false
        }
        guard let managed = try await findManagedRepo(fullName: repo) else {
            throw IDEToolError.handlerFailed(
                "\(repo) isn't set up for releases and isn't accessible to the RxLab GitHub App. Install the GitHub App on this repository, then retry."
            )
        }
        _ = try await release.addRepository(
            AddReleaseRepoBody(
                installationId: managed.installationId,
                repositoryId: managed.id,
                repositoryFullName: managed.fullName
            )
        )
        return true
    }

    /// Finds the accessible GitHub repo matching `fullName` (`owner/repo`) in the
    /// secrets `repositories/all` listing — the source of the `installationId` +
    /// `repositoryId` the docs add-repo API needs. Pages defensively in case the
    /// search filter returns more than one page.
    @MainActor
    private func findManagedRepo(fullName: String) async throws -> SecretsManagedRepo? {
        let target = fullName.lowercased()
        var cursor: String?
        repeat {
            let page = try await secrets.listManagedRepositories(search: fullName, cursor: cursor, pageSize: 100)
            if let match = page.items.first(where: { $0.fullName.lowercased() == target }) {
                return match
            }
            cursor = page.pagination.hasMore ? page.pagination.nextCursor : nil
        } while cursor != nil
        return nil
    }

    private func handleGetUsage() async -> JSONValue {
        let provider = await MainActor.run { selectedAgentProvider }
        let usage = await rateLimitUsage(for: provider, forceRefresh: false)
        guard let usage else {
            return jsonTextResult(.object(["available": .bool(false)]))
        }
        return jsonTextResult(.object([
            "available": .bool(true),
            "provider": .string(provider.rawValue),
            "five_hour_percent": .number(usage.fiveHourPercent),
            "seven_day_percent": .number(usage.sevenDayPercent),
            "twenty_four_hour_percent": usage.twentyFourHourPercent.map { .number($0) } ?? .null,
            "five_hour_resets_at": usage.fiveHourResetsAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "seven_day_resets_at": usage.sevenDayResetsAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
        ]))
    }

    // MARK: - Formatting helpers

    fileprivate func textResult(_ text: String) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                ])
            ])
        ])
    }

    func jsonTextResult(_ value: JSONValue) -> JSONValue {
        textResult(prettyJSON(value))
    }

    fileprivate func prettyJSON(_ value: JSONValue) -> String {
        if let any = jsonValueToAny(value),
           (JSONSerialization.isValidJSONObject(any) || any is [Any]),
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return value.description
    }

    fileprivate func jsonValueToAny(_ value: JSONValue) -> Any? {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr): return arr.map { jsonValueToAny($0) ?? NSNull() }
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = jsonValueToAny(v) ?? NSNull() }
            return out
        }
    }
}
