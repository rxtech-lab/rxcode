import Foundation
import RxCodeCore

extension AppState {
    @MainActor
    func handleGetThreads(arguments: JSONValue) async -> JSONValue {
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
    func handleGetThreadMessages(arguments: JSONValue) async throws -> JSONValue {
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

}
