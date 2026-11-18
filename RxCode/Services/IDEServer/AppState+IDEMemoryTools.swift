import Foundation
import RxCodeCore

extension AppState {
    @MainActor
    func handleMemorySearch(arguments: JSONValue) async throws -> JSONValue {
        guard memoryEnabled else { throw IDEToolError.handlerFailed("Memory is disabled in Settings → General → Memory.") }
        guard let query = arguments["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("missing 'query'")
        }
        let projectId = try parseOptionalProjectId(arguments["project_id"]?.stringValue)
        let limit = Int(min(100, max(1, arguments["limit"]?.numberValue ?? 20)))
        let scope = arguments["scope"]?.stringValue
        guard scope == nil || scope == "global" || scope == "project" || scope == "pet" else { throw IDEToolError.invalidArguments("scope must be global, project, or pet.") }
        let hits = await searchMemoryItems(query: query, projectId: projectId, limit: limit, scope: scope)
        return jsonTextResult(.array(hits.map { memoryJSON(item: $0.item, score: $0.score) }))
    }

    @MainActor
    func handleMemoryAdd(arguments: JSONValue, defaultScope: String = "project") async throws -> JSONValue {
        guard memoryEnabled else {
            throw IDEToolError.handlerFailed("Memory is disabled. Turn on Enable Memory in RxCode Settings → General → Memory, then retry.")
        }
        guard let content = arguments["content"]?.stringValue, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("missing 'content'")
        }
        let scope = arguments["scope"]?.stringValue ?? defaultScope
        guard scope == "global" || scope == "project" || scope == "pet" else { throw IDEToolError.invalidArguments("scope must be global, project, or pet.") }
        let kind = arguments["kind"]?.stringValue ?? "fact"
        let projectId = try parseOptionalProjectId(arguments["project_id"]?.stringValue)
        guard let item = await addMemoryItem(
            content: content,
            projectId: projectId,
            kind: kind,
            scope: scope
        ) else {
            throw IDEToolError.handlerFailed("Memory could not be stored.")
        }
        return jsonTextResult(memoryJSON(item: item, score: nil))
    }

    @MainActor
    func handleMemoryUpdate(arguments: JSONValue) async throws -> JSONValue {
        guard memoryEnabled else {
            throw IDEToolError.handlerFailed("Memory is disabled. Turn on Enable Memory in RxCode Settings → General → Memory, then retry.")
        }
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            throw IDEToolError.invalidArguments("missing 'id'")
        }
        guard let content = arguments["content"]?.stringValue, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("missing 'content'")
        }
        let previous = await allMemoryItems().first { $0.id == id }
        guard let previous else { throw IDEToolError.invalidArguments("No memory with id \(id).") }
        let scope = arguments["scope"]?.stringValue ?? previous.scope
        guard scope == "global" || scope == "project" || scope == "pet" else { throw IDEToolError.invalidArguments("scope must be global, project, or pet.") }
        let projectId = try parseOptionalProjectId(arguments["project_id"]?.stringValue) ?? previous.projectId
        guard let item = await updateMemoryItem(
            id: id,
            content: content,
            projectId: projectId,
            kind: arguments["kind"]?.stringValue ?? previous.kind,
            scope: scope
        ) else {
            throw IDEToolError.handlerFailed("Memory \(id) could not be updated.")
        }
        return jsonTextResult(memoryJSON(item: item, score: nil))
    }

    @MainActor
    func handleMemoryDelete(arguments: JSONValue) async throws -> JSONValue {
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            throw IDEToolError.invalidArguments("missing 'id'")
        }
        await deleteMemoryItem(id: id)
        return textResult("Deleted memory \(id).")
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
}
