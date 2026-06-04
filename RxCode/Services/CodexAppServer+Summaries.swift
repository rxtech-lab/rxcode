import Foundation
import RxCodeCore
import os

extension CodexAppServer {
    func generateSessionTitle(firstUserMessage: String, model: String?) async -> String? {
        guard let binary = await findCodexBinary() else { return nil }
        let trimmedUser = String(firstUserMessage.prefix(500))
        let prompt = """
        Summarize the following user message as a 3-6 word chat title. Reply with ONLY the title, no quotes, no markdown, no punctuation at the end.

        \(trimmedUser)
        """

        let streamId = UUID()
        var title = ""

        do {
            let cwd = FileManager.default.homeDirectoryForCurrentUser.path
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: cwd)
            defer { finalize(streamId: streamId) }

            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)

            var activeThreadId: String?
            var turnStarted = false

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard let object = Self.decodeObject(line) else { continue }

                if let id = Self.idString(object["id"]), object["method"] == nil {
                    switch id {
                    case "1":
                        try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
                        try Self.writeJSONLine(Self.request(id: 2, method: "thread/start", params: threadParams(threadId: nil, cwd: cwd)), to: handles.stdin)
                    case "2":
                        if let result = object["result"] {
                            activeThreadId = Self.threadId(from: result) ?? UUID().uuidString
                        }
                        if let activeThreadId, !turnStarted {
                            try Self.writeJSONLine(Self.request(id: 3, method: "turn/start", params: turnParams(threadId: activeThreadId, prompt: prompt, cwd: cwd, model: model, permissionMode: .default, planMode: false)), to: handles.stdin)
                            turnStarted = true
                        }
                    default:
                        break
                    }
                    continue
                }

                guard let method = object["method"]?.stringValue else { continue }
                if let requestId = Self.idString(object["id"]) {
                    try Self.writeJSONLine(Self.response(id: requestId, result: [:]), to: handles.stdin)
                    continue
                }

                let params = object["params"]?.objectValue ?? [:]
                switch method {
                case "item/agentMessage/delta", "item/agent_message/delta":
                    title += Self.firstString(in: params, keys: ["delta", "text", "content"]) ?? ""
                case "turn/completed":
                    return cleanTitle(title)
                case "turn/failed", "error":
                    return nil
                default:
                    break
                }
            }
        } catch {
            logger.warning("Codex title generation failed: \(error.localizedDescription)")
        }
        return cleanTitle(title)
    }

    func generateResponseNotificationSummary(responseText: String, model: String?) async -> String? {
        guard let binary = await findCodexBinary() else { return nil }
        let trimmedResponse = String(responseText.prefix(4000))
        let prompt = """
        Summarize the following assistant response for a macOS notification. Reply with one concise sentence under 180 characters. Mention the outcome and the most important result. No markdown.

        \(trimmedResponse)
        """

        let streamId = UUID()
        var summary = ""

        do {
            let cwd = FileManager.default.homeDirectoryForCurrentUser.path
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: cwd)
            defer { finalize(streamId: streamId) }

            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)

            var activeThreadId: String?
            var turnStarted = false

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard let object = Self.decodeObject(line) else { continue }

                if let id = Self.idString(object["id"]), object["method"] == nil {
                    switch id {
                    case "1":
                        try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
                        try Self.writeJSONLine(Self.request(id: 2, method: "thread/start", params: threadParams(threadId: nil, cwd: cwd)), to: handles.stdin)
                    case "2":
                        if let result = object["result"] {
                            activeThreadId = Self.threadId(from: result) ?? UUID().uuidString
                        }
                        if let activeThreadId, !turnStarted {
                            try Self.writeJSONLine(Self.request(id: 3, method: "turn/start", params: turnParams(threadId: activeThreadId, prompt: prompt, cwd: cwd, model: model, permissionMode: .default, planMode: false)), to: handles.stdin)
                            turnStarted = true
                        }
                    default:
                        break
                    }
                    continue
                }

                guard let method = object["method"]?.stringValue else { continue }
                if let requestId = Self.idString(object["id"]) {
                    try Self.writeJSONLine(Self.response(id: requestId, result: [:]), to: handles.stdin)
                    continue
                }

                let params = object["params"]?.objectValue ?? [:]
                switch method {
                case "item/agentMessage/delta", "item/agent_message/delta":
                    summary += Self.firstString(in: params, keys: ["delta", "text", "content"]) ?? ""
                case "turn/completed":
                    return cleanNotificationSummary(summary)
                case "turn/failed", "error":
                    return nil
                default:
                    break
                }
            }
        } catch {
            logger.warning("Codex notification summary generation failed: \(error.localizedDescription)")
        }
        return cleanNotificationSummary(summary)
    }

    func generateThreadSummary(
        previousSummary: String?,
        userMessage: String,
        finalResponse: String,
        model: String?
    ) async -> String? {
        let previous = previousSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = """
        Update the stored summary for one project thread. Use the previous summary, latest user request, and final assistant response.
        Keep it factual and concise, 3-6 bullet points max. Include completed work, important decisions, files or areas touched, and unresolved follow-ups.
        Reply with only the updated summary.

        Previous summary:
        \((previous?.isEmpty == false) ? previous! : "None")

        Latest user request:
        \(String(userMessage.prefix(2000)))

        Final assistant response:
        \(String(finalResponse.prefix(4000)))
        """
        guard let raw = await generateCodexPlainSummary(prompt: prompt, model: model) else { return nil }
        return cleanSummary(raw, limit: 1800)
    }

    func generateMemoryOperations(
        existingMemories: [(id: String, content: String)],
        userMessages: [String],
        model: String?
    ) async -> String? {
        let prompt = OpenAISummarizationService.memoryExtractionPrompt(
            existingMemories: existingMemories,
            userMessages: userMessages
        )
        guard let raw = await generateCodexPlainSummary(prompt: prompt, model: model) else { return nil }
        return cleanSummary(raw, limit: 3000)
    }

    func generateBranchBriefing(
        threadSummaries: [(title: String, summary: String)],
        model: String?
    ) async -> String? {
        guard !threadSummaries.isEmpty else { return nil }
        let prompt = OpenAISummarizationService.branchBriefingPrompt(threadSummaries: threadSummaries)
        guard let raw = await generateCodexPlainSummary(prompt: prompt, model: model) else { return nil }
        return cleanSummary(raw, limit: 1800)
    }

    func generateCodexPlainSummary(prompt: String, model: String?) async -> String? {
        guard let binary = await findCodexBinary() else { return nil }
        let streamId = UUID()
        var summary = ""

        do {
            let cwd = FileManager.default.homeDirectoryForCurrentUser.path
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: cwd)
            defer { finalize(streamId: streamId) }

            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)

            var activeThreadId: String?
            var turnStarted = false

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard let object = Self.decodeObject(line) else { continue }

                if let id = Self.idString(object["id"]), object["method"] == nil {
                    switch id {
                    case "1":
                        try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
                        try Self.writeJSONLine(Self.request(id: 2, method: "thread/start", params: threadParams(threadId: nil, cwd: cwd)), to: handles.stdin)
                    case "2":
                        if let result = object["result"] {
                            activeThreadId = Self.threadId(from: result) ?? UUID().uuidString
                        }
                        if let activeThreadId, !turnStarted {
                            try Self.writeJSONLine(Self.request(id: 3, method: "turn/start", params: turnParams(threadId: activeThreadId, prompt: prompt, cwd: cwd, model: model, permissionMode: .default, planMode: false)), to: handles.stdin)
                            turnStarted = true
                        }
                    default:
                        break
                    }
                    continue
                }

                guard let method = object["method"]?.stringValue else { continue }
                if let requestId = Self.idString(object["id"]) {
                    try Self.writeJSONLine(Self.response(id: requestId, result: [:]), to: handles.stdin)
                    continue
                }

                let params = object["params"]?.objectValue ?? [:]
                switch method {
                case "item/agentMessage/delta", "item/agent_message/delta":
                    summary += Self.firstString(in: params, keys: ["delta", "text", "content"]) ?? ""
                case "turn/completed":
                    return summary
                case "turn/failed", "error":
                    return nil
                default:
                    break
                }
            }
        } catch {
            logger.warning("Codex summary generation failed: \(error.localizedDescription)")
        }
        return summary
    }

    func cleanTitle(_ raw: String) -> String? {
        let cleaned = ChatSession.stripMarkdownEmphasis(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty else { return nil }

        let lower = cleaned.lowercased()
        let errorPrefixes = ["api error", "error:", "execution error", "request failed", "codex error"]
        guard !errorPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return String(cleaned.prefix(80))
    }

    func cleanNotificationSummary(_ raw: String) -> String? {
        cleanSummary(raw, limit: 180)
    }

    func cleanSummary(_ raw: String, limit: Int) -> String? {
        let errorPrefixes = ["api error", "error:", "execution error", "request failed", "codex error"]
        return GeneratedTextSanitizer.cleanSummary(raw, limit: limit, errorPrefixes: errorPrefixes)
    }
}
