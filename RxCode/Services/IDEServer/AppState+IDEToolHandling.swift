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
        case "ide__get_threads":
            return await handleGetThreads(arguments: arguments)
        case "ide__get_thread_detail":
            return try await handleGetThreadDetail(arguments: arguments)
        case "ide__get_usage":
            return await handleGetUsage()
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
    private func handleGetThreads(arguments: JSONValue) -> JSONValue {
        let projectFilter: UUID? = {
            if let s = arguments["project_id"]?.stringValue { return UUID(uuidString: s) }
            return nil
        }()
        let summaries = threadStore.loadAllSummaries()
        let filtered = summaries
            .filter { projectFilter == nil || $0.projectId == projectFilter }
            .filter { !$0.isArchived }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(50)
        let entries: [JSONValue] = filtered.map { s in
            .object([
                "id": .string(s.id),
                "title": .string(s.title),
                "project_id": .string(s.projectId.uuidString),
                "updated_at": .string(ISO8601DateFormatter().string(from: s.updatedAt)),
                "agent_provider": .string(s.agentProvider.rawValue),
            ])
        }
        return jsonTextResult(.array(entries))
    }

    @MainActor
    private func handleGetThreadDetail(arguments: JSONValue) throws -> JSONValue {
        guard let id = arguments["thread_id"]?.stringValue else {
            throw IDEToolError.invalidArguments("missing 'thread_id'")
        }
        guard let thread = threadStore.fetch(id: id) else {
            throw IDEToolError.handlerFailed("No thread with id \(id)")
        }
        // ChatThread is the SwiftData summary record; the full message
        // body is persisted by ChatSession on disk. Return the metadata
        // here — a future revision can hydrate ChatSession via
        // PersistenceService.loadSession for richer detail.
        return jsonTextResult(.object([
            "id": .string(thread.id),
            "title": .string(thread.title),
            "project_id": .string(thread.projectId.uuidString),
            "created_at": .string(ISO8601DateFormatter().string(from: thread.createdAt)),
            "updated_at": .string(ISO8601DateFormatter().string(from: thread.updatedAt)),
            "model": thread.model.map { .string($0) } ?? .null,
            "agent_provider": thread.agentProviderRaw.map { .string($0) } ?? .null,
        ]))
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
