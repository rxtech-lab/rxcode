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
//   • Polyfill tools (`ide__set_todos`) are filtered out
//     for backends that natively support the feature — see
//     `IDEToolRegistry.tools(for:)`.
//   • IDE-only tools (`ide__get_running_jobs`, `ide__ask_user` etc.) always
//     appear so any agent can introspect editor state and ask questions.
//
// `sessionKey` is the AppState session key the agent is bound to. The
// listener allocates one port per session, so this is unambiguous.

extension AppState {
    public func ideAvailableTools(forSession sessionKey: String) async -> [IDETool] {
        let provider = ideAgentProvider(for: sessionKey)
        let caps = await backend(for: provider).capabilities(for: sessionKey)
        return IDEToolRegistry.tools(for: caps)
    }

    private func ideAgentProvider(for sessionKey: String) -> AgentProvider {
        sessionStates[resolveCurrentSessionId(sessionKey)]?.agentProvider
            ?? sessionStates[sessionKey]?.agentProvider
            ?? .acp
    }

    public func ideHandleToolCall(
        name: String,
        arguments: JSONValue,
        sessionKey: String
    ) async throws -> JSONValue {
        if sessionKey.hasPrefix("pet-codex-realtime-") {
            return try await PetController.shared.withRealtimeIDEToolActivity(name: name) {
                try await self.dispatchIDEToolCall(name: name, arguments: arguments, sessionKey: sessionKey)
            }
        }
        return try await dispatchIDEToolCall(name: name, arguments: arguments, sessionKey: sessionKey)
    }

    private func dispatchIDEToolCall(
        name: String,
        arguments: JSONValue,
        sessionKey: String
    ) async throws -> JSONValue {
        switch name {
        case "ide__skill_get":
            let skillName = arguments["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !skillName.isEmpty else { throw IDEToolError.invalidArguments("Pass an RxCode skill name.") }
            return textResult(try await marketplace.skillContent(named: skillName, for: ideAgentProvider(for: sessionKey)))
        case "ide__media_models", "ide__generate_media", "ide__pet_draft":
            return try await handleMediaTool(name: name, arguments: arguments, sessionKey: sessionKey)
        case FlowcyTool.name, FlowcyTool.catalogName, "ide__get_ci_status":
            return try await handleFlowcyTool(name: name, arguments: arguments, sessionKey: sessionKey)
        case "ide__pet_show_image":
            return try await PetController.shared.presentation.showImage(arguments)
        case "ide__pet_status":
            return try await PetController.shared.presentation.setWidget(arguments)
        case "ide__pet_look":
            return try await PetController.shared.looks.handle(arguments)
        case "ide__pet_music":
            return try await PetController.shared.music.handle(arguments)
        case "ide__pet_list_desktop_targets":
            return await PetController.shared.desktopActions.listTargets()
        case "ide__pet_click", "ide__pet_scroll", "ide__pet_focus_window", "ide__pet_type_text":
            let action = name == "ide__pet_click" ? "click" : name == "ide__pet_scroll" ? "scroll" : name == "ide__pet_type_text" ? "type" : "focus"
            return try await PetController.shared.desktopActions.run(action, arguments: arguments)
        case "ide__pet_list_capture_targets":
            return try await PetController.shared.screenCapture.listTargets()
        case "ide__pet_capture":
            return try await PetController.shared.screenCapture.capture(arguments)
        case "ide__set_todos":
            return try handleSetTodos(arguments: arguments, sessionKey: sessionKey)
        case "ide__get_running_jobs":
            return handleGetRunningJobs()
        case "ide__get_job_output":
            throw IDEToolError.notSupported("ide__get_job_output is not yet implemented")
        case "ide__get_projects":
            return handleGetProjects()
        case "ide__get_stories":
            return try await handleGetStories(arguments: arguments, sessionKey: sessionKey)
        case TaskViewsTool.name:
            return try await handleTaskViews(arguments: arguments, sessionKey: sessionKey)
        case "ide__create_story":
            return try await handleCreateStory(arguments: arguments, sessionKey: sessionKey)
        case "ide__create_task":
            return try await handleCreateTask(arguments: arguments, sessionKey: sessionKey)
        case "ide__search_huggingface_models":
            return try await handleSearchHuggingFaceModels(arguments: arguments)
        case "ide__list_agent_models":
            return handleListAgentModels()
        case JSONUITool.ideName:
            return try await handleShowUI(arguments: arguments, sessionKey: sessionKey)
        case ConfirmationTool.ideName:
            return try await handleShowConfirmation(arguments: arguments, sessionKey: sessionKey)
        case "ide__update_task":
            return try await handleUpdateTask(arguments: arguments)
        case "ide__delete_task":
            return try await handleDeleteTask(arguments: arguments)
        case "ide__link_story":
            return try await handleLinkStory(arguments: arguments, sessionKey: sessionKey)
        case "ide__create_scheduled_task":
            return try await handleCreateScheduledTask(arguments: arguments, sessionKey: sessionKey)
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
        case "ide__usage_cards":
            return try await handleUsageCards(arguments)
        case "ide__get_integration_usage":
            return try await handleGetIntegrationUsage(arguments)
        case "ide__get_usage":
            return await handleGetUsage()
        case "ide__search_docs":
            return try await handleSearchDocs(arguments: arguments)
        case "ide__setup_docs_secret":
            return try await handleSetupDocsSecret(arguments: arguments, sessionKey: sessionKey)
        case "ide__setup_release":
            return try await handleSetupRelease(arguments: arguments, sessionKey: sessionKey)
        case "ide__project_briefings", "ide__project_briefing_get",
             "ide__briefing_list", "ide__briefing_get", "ide__briefing_create",
             "ide__briefing_update", "ide__briefing_delete", "ide__briefing_add_file",
             "ide__briefing_delete_file", "ide__briefing_publish":
            return try await handleBriefingToolCall(name: name, arguments: arguments, sessionKey: sessionKey)
        case "ide__send_notification":
            return try await handleSendNotification(arguments: arguments, sessionKey: sessionKey)
        case "ide__ask_user":
            return try await handleAskUser(arguments: arguments, sessionKey: sessionKey)
        default:
            throw IDEToolError.unknownTool(name)
        }
    }

    // MARK: - Handlers

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
    func taskToolProjectId(arguments: JSONValue, sessionKey: String) throws -> UUID {
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
        let parentTaskIds: [UUID]
        let requestedParents: [String]
        if let entries = arguments["starts_after_task_ids"]?.arrayValue {
            guard entries.allSatisfy({ $0.stringValue != nil }) else {
                throw IDEToolError.invalidArguments("starts_after_task_ids must contain task id strings.")
            }
            requestedParents = entries.compactMap(\.stringValue)
        } else {
            requestedParents = arguments["starts_after_task_id"]?.stringValue.map { [$0] } ?? []
        }
        if !requestedParents.isEmpty {
            await ensureAllTaskBoardsLoaded()
            parentTaskIds = try requestedParents.map { raw in
                guard let id = UUID(uuidString: raw), self.task(id: id) != nil else {
                    throw IDEToolError.invalidArguments("Each starts_after_task_ids entry must identify an existing task. Call ide__get_tasks first.")
                }
                return id
            }
        } else {
            parentTaskIds = []
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
            task = quickAddTask(text: details, projectId: projectId, storyId: storyId,
                                parentTaskIds: parentTaskIds, sourceSessionKey: sessionKey)
        } else {
            let story = taskBoard(for: projectId).story(id: storyId)
            task = ProjectTask(
                projectId: projectId,
                storyId: storyId,
                parentTaskIds: parentTaskIds,
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
            "starts_after_task_id": (self.task(id: task.id)?.parentTaskId).map { .string($0.uuidString) } ?? .null,
            "starts_after_task_ids": .array((self.task(id: task.id)?.parentTaskIds ?? []).map { .string($0.uuidString) }),
            "title": .string(task.title),
        ]))
    }

    func parseTaskId(_ arguments: JSONValue) throws -> ProjectTask {
        guard let raw = arguments["task_id"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw IDEToolError.invalidArguments("A valid task_id is required.")
        }
        guard let task = task(id: id) else {
            throw IDEToolError.invalidArguments("No task with id \(raw). Call ide__get_tasks first.")
        }
        return task
    }

    func taskJSON(_ task: ProjectTask) -> [String: JSONValue] {
        let board = taskBoard(for: task.projectId)
        let column = board.column(for: task.status)
        return [
            "id": .string(task.id.uuidString),
            "project_id": .string(task.projectId.uuidString),
            "project_name": projects.first(where: { $0.id == task.projectId }).map { .string($0.name) } ?? .null,
            "story_id": task.storyId.map { .string($0.uuidString) } ?? .null,
            "parent_task_id": task.parentTaskId.map { .string($0.uuidString) } ?? .null,
            "parent_task_ids": .array(task.parentTaskIds.map { .string($0.uuidString) }),
            "title": .string(task.title),
            "details": .string(task.details),
            "tags": .array(task.tags.map { .string($0) }),
            "priority": task.priority.map { .string($0.rawValue) } ?? .null,
            "version": task.version.map { .string($0) } ?? .null,
            "milestone": task.milestone.map { .string($0) } ?? .null,
            "type_id": task.typeId.map { .string($0.uuidString) } ?? .null,
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

        if let device = otherRunDeviceName(for: task) {
            throw IDEToolError.handlerFailed("The task is already running on \(device).")
        }
        if board.resolvedStatus(of: task) == chatColumn.id {
            // Already sitting in the chat column without a live run (e.g. a
            // released run): moving it there again would not dispatch.
            task = claimedForThisDevice(task)
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

    func parseOptionalProjectId(_ raw: String?) throws -> UUID? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let id = UUID(uuidString: raw) else {
            throw IDEToolError.invalidArguments("'project_id' is not a valid UUID: \(raw)")
        }
        return id
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

    func textResult(_ text: String) -> JSONValue {
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
