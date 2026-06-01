import Foundation
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
    private func handleGetThreads(arguments: JSONValue) async -> JSONValue {
        let projectFilter: UUID? = {
            if let s = arguments["project_id"]?.stringValue { return UUID(uuidString: s) }
            return nil
        }()
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedLimit = Int(arguments["limit"]?.numberValue ?? 50)
        let limit = max(1, min(requestedLimit, 200))

        let summaries = threadStore.loadAllSummaries()
        let byId = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let iso = ISO8601DateFormatter()

        func emit(summary: ChatSession.Summary, score: Float?, snippet: String?) -> JSONValue {
            let storedSummary = threadStore.fetchThreadSummary(sessionId: summary.id)?.summary ?? ""
            var obj: [String: JSONValue] = [
                "id": .string(summary.id),
                "title": .string(summary.title),
                "project_id": .string(summary.projectId.uuidString),
                "updated_at": .string(iso.string(from: summary.updatedAt)),
                "agent_provider": .string(summary.agentProvider.rawValue),
                "summary": .string(storedSummary),
                "branch": summary.worktreeBranch.map { .string($0) } ?? .null,
                "is_archived": .bool(summary.isArchived),
                "worktree_branch": summary.worktreeBranch.map { .string($0) } ?? .null,
            ]
            if let score { obj["score"] = .number(Double(score)) }
            if let snippet { obj["snippet"] = .string(snippet) }
            return .object(obj)
        }

        if let query, !query.isEmpty {
            // Semantic search via the same on-device embedding pipeline that
            // powers the global search overlay. Flatten the project groups so
            // we can apply an optional project filter while preserving rank.
            let groups = await searchService.search(query, limit: limit)
            let flat = groups.flatMap { $0.hits }
            let filtered = flat.filter { hit in
                guard let pid = projectFilter else { return true }
                return hit.projectId == pid
            }
            let entries: [JSONValue] = filtered.prefix(limit).compactMap { hit in
                guard let summary = byId[hit.threadId] else { return nil }
                if summary.isArchived { return nil }
                return emit(summary: summary, score: hit.score, snippet: hit.snippet)
            }
            return jsonTextResult(.array(entries))
        } else {
            let filtered = summaries
                .filter { projectFilter == nil || $0.projectId == projectFilter }
                .filter { !$0.isArchived }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
            let entries: [JSONValue] = filtered.map { emit(summary: $0, score: nil, snippet: nil) }
            return jsonTextResult(.array(entries))
        }
    }

    @MainActor
    private func handleGetThreadMessages(arguments: JSONValue) async throws -> JSONValue {
        guard let id = arguments["thread_id"]?.stringValue else {
            throw IDEToolError.invalidArguments("missing 'thread_id'")
        }
        guard let thread = threadStore.fetch(id: id) else {
            throw IDEToolError.handlerFailed("No thread with id \(id)")
        }
        let summary = thread.toSummary()
        let cwd = summary.worktreePath
            ?? projects.first(where: { $0.id == summary.projectId })?.path
            ?? ""
        let requestedLimit = Int(arguments["limit"]?.numberValue ?? 200)
        let limit = max(1, min(requestedLimit, 1000))
        let includeToolCalls = arguments["include_tool_calls"]?.boolValue ?? false

        let session = await persistence.loadFullSession(summary: summary, cwd: cwd)
        let allMessages = session?.messages ?? []
        // Most-recent N — preserve chronological order in the output.
        let tail = Array(allMessages.suffix(limit))
        let iso = ISO8601DateFormatter()

        let messageEntries: [JSONValue] = tail.compactMap { msg in
            // Concatenate text blocks; optionally append a one-line summary for
            // each tool call so a reader can tell what happened without the
            // full result payload.
            var pieces: [String] = []
            for block in msg.blocks {
                if let text = block.text, !text.isEmpty {
                    pieces.append(text)
                } else if let call = block.toolCall, includeToolCalls {
                    let resultPreview = call.result.map { $0.prefix(200) }.map(String.init) ?? ""
                    pieces.append("[tool: \(call.name)\(call.isError ? " (error)" : "")] \(resultPreview)")
                }
            }
            let text = pieces.joined(separator: "\n\n")
            if text.isEmpty && !msg.isError { return nil }
            var obj: [String: JSONValue] = [
                "role": .string(msg.role.rawValue),
                "text": .string(text),
                "timestamp": .string(iso.string(from: msg.timestamp)),
            ]
            if msg.isError { obj["is_error"] = .bool(true) }
            if !msg.attachmentPaths.isEmpty {
                obj["attachments"] = .array(msg.attachmentPaths.map { att in
                    .object([
                        "name": .string(att.name),
                        "path": .string(att.path),
                        "type": .string(att.type),
                    ])
                })
            }
            return .object(obj)
        }

        return jsonTextResult(.object([
            "id": .string(thread.id),
            "title": .string(thread.title),
            "project_id": .string(thread.projectId.uuidString),
            "created_at": .string(iso.string(from: thread.createdAt)),
            "updated_at": .string(iso.string(from: thread.updatedAt)),
            "model": thread.model.map { .string($0) } ?? .null,
            "agent_provider": thread.agentProviderRaw.map { .string($0) } ?? .null,
            "summary": .string(threadStore.fetchThreadSummary(sessionId: thread.id)?.summary ?? ""),
            "messages": .array(messageEntries),
        ]))
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
        let requestedTimeout = arguments["timeout_seconds"]?.numberValue ?? 120
        let timeoutSeconds = max(1, min(requestedTimeout, 600))

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
                timeoutSeconds: timeoutSeconds
            )
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
            throw IDEToolError.handlerFailed(error.localizedDescription)
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

    fileprivate func jsonTextResult(_ value: JSONValue) -> JSONValue {
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
