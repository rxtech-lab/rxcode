import Foundation
import os
import RxCodeChatKit
import RxCodeCore
import RxCodeSync
import SwiftUI

extension AppState {
    // MARK: - Memory

    func ensureMemoryStarted() async {
        await memoryService.start(threadStore: threadStore, keepsGlobalRows: activeWorkspace.isPersonal)
    }

    func configureMemoryMCPServer(enabled: Bool, port: Int, exposedTools: Set<MCPServerTool>) async {
        await core.memoryMCPServer.setHandler(self)
        do {
            try await core.memoryMCPServer.configureMemoryAPI(
                enabled: enabled && memoryEnabled,
                port: port,
                exposedTools: exposedTools
            )
            memoryMCPServerRunning = enabled && memoryEnabled
            memoryMCPServerError = nil
        } catch {
            memoryMCPServerRunning = false
            memoryMCPServerError = error.localizedDescription
        }
    }

    func allMemoryItems() async -> [MemoryItem] {
        await ensureMemoryStarted()
        return await memoryService.allMemories()
    }

    func searchMemoryItems(query: String, projectId: UUID? = nil, limit: Int = 50, scope: String? = nil, includePet: Bool = false) async -> [MemoryService.Hit] {
        await ensureMemoryStarted()
        return await memoryService.search(query, projectId: projectId, limit: limit, scope: scope, includePet: includePet)
    }

    @discardableResult
    func addMemoryItem(content: String, projectId: UUID?, kind: String = "fact", scope: String = "project") async -> MemoryItem? {
        guard memoryEnabled else { return nil }
        await ensureMemoryStarted()
        let scope = normalizedMemoryScope(scope)
        let item = await memoryService.addMemory(
            content: content,
            projectId: scope == "project" ? projectId : nil,
            sessionId: nil,
            sourceMessageId: nil,
            kind: normalizedMemoryKind(kind),
            scope: scope
        )
        if item != nil { memoryRevision &+= 1 }
        return item
    }

    @discardableResult
    func updateMemoryItem(id: String, content: String, projectId: UUID?, kind: String, scope: String) async -> MemoryItem? {
        guard memoryEnabled else { return nil }
        await ensureMemoryStarted()
        let scope = normalizedMemoryScope(scope)
        let item = await memoryService.updateMemory(
            id: id,
            content: content,
            projectId: scope == "project" ? projectId : nil,
            sessionId: nil,
            sourceMessageId: nil,
            kind: normalizedMemoryKind(kind),
            scope: scope
        )
        if item != nil { memoryRevision &+= 1 }
        return item
    }

    func deleteMemoryItem(id: String) async {
        await ensureMemoryStarted()
        await memoryService.deleteMemory(id: id)
        memoryRevision &+= 1
    }

    func deleteAllMemoryItems(projectId: UUID? = nil) async {
        await ensureMemoryStarted()
        await memoryService.deleteAll(projectId: projectId)
        memoryRevision &+= 1
    }

    func memoryContextSystemPrompt(relatedHits: [MemoryService.Hit]) -> String {
        guard memoryEnabled, memoryInjectEnabled, !relatedHits.isEmpty else { return "" }

        let relatedLines = relatedHits
            .prefix(memoryMaxContextItems)
            .enumerated()
            .map { idx, hit in
                "\(idx + 1). \(hit.item.content)"
            }
            .joined(separator: "\n")

        return """
        # Relevant user memory

        Saved preferences and facts; possibly stale. The user request takes priority.
        \(relatedLines)
        """
    }

    func memoryContextPromptPrefix(for context: String, prompt: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt }
        return """
        \(trimmed)

        User request:
        \(prompt)
        """
    }

    func scheduleMemoryExtraction(
        sessionId: String,
        projectId: UUID,
        messages: [ChatMessage]
    ) {
        guard memoryEnabled, memoryAutoCreateEnabled else { return }
        let userMessages = userMessageTexts(in: messages)
        guard !userMessages.isEmpty else { return }
        let sourceMessageId = messages.last(where: { $0.role == .user && !$0.isError })?.id
        let summary = allSessionSummaries.first(where: { $0.id == sessionId })
            ?? summaryFor(sessionId: sessionId, projectId: projectId)

        Task { [weak self] in
            guard let self else { return }
            await self.extractAndStoreMemories(
                sessionId: sessionId,
                projectId: projectId,
                sourceMessageId: sourceMessageId,
                userMessages: userMessages,
                summary: summary
            )
        }
    }

    func extractAndStoreMemories(
        sessionId: String,
        projectId: UUID,
        sourceMessageId: UUID?,
        userMessages: [String],
        summary: ChatSession.Summary
    ) async {
        let memorySource = userMessages.joined(separator: "\n\n")
        let relatedHits = await memoryService.search(
            memorySource,
            projectId: projectId,
            limit: 6
        )
        let related = relatedHits.map { (id: $0.item.id, content: $0.item.content) }
        guard let raw = await generateMemoryOperations(
            existingMemories: related,
            userMessages: userMessages,
            summary: summary
        ) else { return }
        let operations = Self.parseMemoryOperations(raw)
        guard !operations.isEmpty else { return }

        var changed = false
        for operation in operations {
            switch operation.action {
            case "add":
                guard let content = operation.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { continue }
                let scope = normalizedMemoryScope(operation.scope)
                let existing = await memoryService.search(content, projectId: projectId, limit: 1)
                if let best = existing.first, best.score > 0.94 { continue }
                if await memoryService.addMemory(
                    content: content,
                    projectId: scope == "project" ? projectId : nil,
                    sessionId: sessionId,
                    sourceMessageId: sourceMessageId,
                    kind: normalizedMemoryKind(operation.kind),
                    scope: scope
                ) != nil {
                    changed = true
                }
            case "update":
                guard let id = operation.id,
                      let content = operation.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty else { continue }
                let scope = normalizedMemoryScope(operation.scope)
                if await memoryService.updateMemory(
                    id: id,
                    content: content,
                    projectId: scope == "project" ? projectId : nil,
                    sessionId: sessionId,
                    sourceMessageId: sourceMessageId,
                    kind: normalizedMemoryKind(operation.kind),
                    scope: scope
                ) != nil {
                    changed = true
                }
            case "delete":
                guard let id = operation.id else { continue }
                await memoryService.deleteMemory(id: id)
                changed = true
            default:
                continue
            }
        }
        if changed {
            memoryRevision &+= 1
        }
    }

    struct MemoryOperation {
        let action: String
        let id: String?
        let content: String?
        let kind: String?
        let scope: String?
    }

    static func parseMemoryOperations(_ raw: String) -> [MemoryOperation] {
        let trimmed = stripJSONFence(raw)
        guard let range = jsonArrayRange(in: trimmed) else { return [] }
        let json = String(trimmed[range])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { entry in
            guard let action = entry["action"] as? String else { return nil }
            return MemoryOperation(
                action: action.lowercased(),
                id: entry["id"] as? String,
                content: entry["content"] as? String,
                kind: entry["kind"] as? String,
                scope: entry["scope"] as? String
            )
        }
    }

    static func stripJSONFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            if !lines.isEmpty { lines.removeFirst() }
            if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
                lines.removeLast()
            }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    static func jsonArrayRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start <= end else { return nil }
        return start..<text.index(after: end)
    }

    func normalizedMemoryKind(_ value: String?) -> String {
        switch value?.lowercased() {
        case "preference", "decision", "fact":
            return value!.lowercased()
        default:
            return "fact"
        }
    }

    func normalizedMemoryScope(_ value: String?) -> String {
        switch value?.lowercased() {
        case "global": "global"
        case "pet": "pet"
        default: "project"
        }
    }
}
