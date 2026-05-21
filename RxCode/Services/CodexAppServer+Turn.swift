import Foundation
import RxCodeCore
import os

extension CodexAppServer {
    func runTurn(
        streamId: UUID,
        prompt: String,
        cwd: String,
        threadId: String?,
        model: String?,
        permissionMode: PermissionMode,
        planMode: Bool,
        mcpConfigOverrides: [String],
        permissionServer: PermissionServer,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) async {
        do {
            guard let binary = await findCodexBinary() else { throw CodexError.binaryNotFound }
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: cwd, configOverrides: mcpConfigOverrides)
            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)

            // Surface the IDE tools blurb as developer instructions only when
            // the `rxcode-ide` MCP bridge is wired into this turn's overrides.
            let ideInstructions = Self.includesIDEServer(mcpConfigOverrides) ? Self.ideToolsDeveloperInstructions : nil
            var activeThreadId = threadId
            var turnStarted = false
            var turnCompleted = false
            var finalUsage: UsageInfo?
            let startedAt = Date()
            // Captured per turn so we can synthesize an `ExitPlanMode` tool call when a
            // plan-mode turn completes. Codex never emits ExitPlanMode itself — its plan
            // arrives as `turn/plan/updated` notifications (steps) and a final agent
            // message (concise summary). See PlanCardView for the rendering contract.
            var planItems: [TodoItem] = []
            var assistantTextBuffer = ""

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard !Task.isCancelled else { break }
                guard let object = Self.decodeObject(line) else { continue }

                if let id = Self.idString(object["id"]), object["method"] == nil {
                    switch id {
                    case "1":
                        try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
                        let method = activeThreadId == nil ? "thread/start" : "thread/resume"
                        let params = method == "thread/start"
                            ? threadStartParams(threadId: activeThreadId, cwd: cwd, permissionMode: permissionMode, planMode: planMode, ideInstructions: ideInstructions)
                            : threadParams(threadId: activeThreadId, cwd: cwd)
                        try Self.writeJSONLine(Self.request(id: 2, method: method, params: params), to: handles.stdin)
                    case "2":
                        if let result = object["result"] {
                            activeThreadId = Self.threadId(from: result) ?? activeThreadId ?? UUID().uuidString
                            continuation.yield(.system(SystemEvent(
                                subtype: "init",
                                sessionId: activeThreadId,
                                tools: nil,
                                model: model,
                                claudeCodeVersion: nil
                            )))
                        }
                        if let activeThreadId, !turnStarted {
                            try Self.writeJSONLine(Self.request(id: 3, method: "turn/start", params: turnParams(threadId: activeThreadId, prompt: prompt, cwd: cwd, model: model, permissionMode: permissionMode, planMode: planMode)), to: handles.stdin)
                            turnStarted = true
                        }
                    case "3":
                        break
                    default:
                        break
                    }
                    continue
                }

                if let method = object["method"]?.stringValue {
                    if let requestId = Self.idString(object["id"]) {
                        try await handleServerRequest(
                            requestId: requestId,
                            method: method,
                            object: object,
                            activeThreadId: activeThreadId,
                            permissionMode: permissionMode,
                            planMode: planMode,
                            permissionServer: permissionServer,
                            stdin: handles.stdin
                        )
                    } else {
                        let params = object["params"]?.objectValue ?? [:]
                        switch method {
                        case "turn/plan/updated":
                            if let items = TodoExtractor.parseCodexPlanUpdate(params: params) {
                                planItems = items
                            }
                        case "item/agentMessage/delta", "item/agent_message/delta":
                            if let text = Self.firstString(in: params, keys: ["delta", "text", "content"]) {
                                assistantTextBuffer += text
                            }
                        default:
                            break
                        }
                        handleNotification(method: method, object: object, activeThreadId: activeThreadId, continuation: continuation)
                        if method == "turn/completed" || method == "turn/failed" {
                            finalUsage = Self.usageInfo(from: object) ?? finalUsage
                            turnCompleted = method == "turn/completed"
                            if turnCompleted, planMode {
                                emitSynthesizedExitPlanMode(
                                    planItems: planItems,
                                    assistantText: assistantTextBuffer,
                                    continuation: continuation
                                )
                            }
                            break
                        }
                    }
                }
            }

            let sid = activeThreadId ?? threadId ?? UUID().uuidString
            let duration = Date().timeIntervalSince(startedAt) * 1000
            continuation.yield(.result(ResultEvent(
                durationMs: duration,
                totalCostUsd: nil,
                sessionId: sid,
                isError: !turnCompleted,
                totalTurns: 1,
                usage: finalUsage,
                contextWindow: nil
            )))
        } catch {
            stderrBuffers[streamId, default: ""] += "\n\(error.localizedDescription)"
            let sid = threadId ?? "codex-\(streamId.uuidString)"
            continuation.yield(.result(ResultEvent(
                durationMs: nil,
                totalCostUsd: nil,
                sessionId: sid,
                isError: true,
                totalTurns: nil,
                usage: nil,
                contextWindow: nil
            )))
        }
        finalize(streamId: streamId)
        continuation.finish()
    }

    func handleNotification(
        method: String,
        object: [String: JSONValue],
        activeThreadId: String?,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) {
        let params = object["params"]?.objectValue ?? [:]
        notificationMethodCounts[method, default: 0] += 1
        if notificationMethodCounts[method] == 1 {
            logger.info("[CodexAppServer] notification method=\(method, privacy: .public)")
        }

        let liveUsage = method == "thread/tokenUsage/updated"
            ? Self.liveTokenUsage(from: params)
            : nil
        if method == "thread/tokenUsage/updated" {
            let outputTokens = Self.tokenUsageOutputTokens(from: params) ?? 0
            let tokenUsage = Self.tokenUsageTokensUsed(from: params) ?? 0
            let tokenBudget = Self.tokenUsageTokenBudget(from: params) ?? 0
            logger.info("[CodexAppServer] tokenUsage.updated outputTokens=\(outputTokens) tokensUsed=\(tokenUsage) tokenBudget=\(tokenBudget) parsedOutput=\(liveUsage?.outputTokens ?? 0)")
            if liveUsage?.outputTokens ?? 0 == 0 {
                logger.info("[CodexAppServer] tokenUsage.payload \(JSONValue.object(params).description, privacy: .public)")
            }
        }
        if let usage = liveUsage ?? Self.usageInfo(from: object) {
            continuation.yield(.assistant(AssistantMessage(
                id: Self.usageMessageId(from: params, fallback: activeThreadId),
                role: "assistant",
                content: [],
                usage: usage
            )))
        }
        switch method {
        case "thread/started":
            let sid = Self.threadId(from: .object(params)) ?? activeThreadId
            continuation.yield(.system(SystemEvent(subtype: "init", sessionId: sid, tools: nil, model: nil, claudeCodeVersion: nil)))
        case "item/agentMessage/delta", "item/agent_message/delta":
            if let text = Self.firstString(in: params, keys: ["delta", "text", "content"]) {
                continuation.yield(.unknown(Self.claudeTextDelta(text)))
            }
        case "item/reasoning/textDelta",
             "item/reasoning/summaryTextDelta",
             "item/reasoning/summaryPartAdded":
            let text = Self.firstString(in: params, keys: ["delta", "text", "content", "summary"]) ?? ""
            continuation.yield(.unknown(Self.claudeThinkingDelta(text)))
        case "item/started":
            if let item = params["item"]?.objectValue ?? params["itemInfo"]?.objectValue {
                emitToolStart(item: item, continuation: continuation)
            }
        case "turn/plan/updated":
            if let items = TodoExtractor.parseCodexPlanUpdate(params: params) {
                let sessionId = Self.firstString(in: params, keys: ["threadId", "thread_id"]) ?? activeThreadId
                continuation.yield(.todoSnapshot(TodoSnapshotEvent(sessionId: sessionId, items: items)))
            }
        case "item/completed":
            if let item = params["item"]?.objectValue ?? params["itemInfo"]?.objectValue {
                emitToolCompletion(item: item, continuation: continuation)
            }
        case "error", "turn/failed":
            if let message = Self.firstString(in: params, keys: ["message", "error"]) {
                continuation.yield(.unknown(Self.claudeTextDelta(message)))
            }
        default:
            break
        }
    }

    func emitToolStart(item: [String: JSONValue], continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let name = toolName(from: item), name != "message" else { return }
        let id = Self.firstString(in: item, keys: ["id", "itemId", "callId"]) ?? UUID().uuidString
        let input = item["input"]?.objectValue ?? item["arguments"]?.objectValue ?? item
        continuation.yield(.unknown(Self.claudeToolStart(id: id, name: name)))
        continuation.yield(.unknown(Self.claudeInputDelta(input)))
        continuation.yield(.unknown(Self.claudeContentBlockStop()))
    }

    func emitToolCompletion(item: [String: JSONValue], continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let name = toolName(from: item), name != "message" else { return }
        let id = Self.firstString(in: item, keys: ["id", "itemId", "callId"]) ?? UUID().uuidString
        let output = Self.firstString(in: item, keys: ["output", "result", "summary", "message"]) ?? ""
        let isError = item["error"] != nil || item["isError"]?.boolValue == true
        continuation.yield(.user(UserMessage(toolUseId: id, content: output, isError: isError)))
    }

    /// Synthesize a Claude-shaped `ExitPlanMode` tool call so `PlanCardView` can render
    /// an interactive accept/reject card at the end of a Codex plan-mode turn. Plan body
    /// is rendered from the latest `update_plan` steps; falls back to the assistant's
    /// final summary text if no plan steps were emitted.
    func emitSynthesizedExitPlanMode(
        planItems: [TodoItem],
        assistantText: String,
        continuation: AsyncStream<StreamEvent>.Continuation
    ) {
        let stepsMarkdown = Self.planItemsMarkdown(planItems)
        let trimmedText = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown: String
        if !stepsMarkdown.isEmpty {
            markdown = stepsMarkdown
        } else if !trimmedText.isEmpty {
            markdown = trimmedText
        } else {
            return
        }
        let id = "codex-plan-\(UUID().uuidString)"
        continuation.yield(.unknown(Self.claudeToolStart(id: id, name: "ExitPlanMode")))
        continuation.yield(.unknown(Self.claudeInputDelta(["plan": .string(markdown)])))
        continuation.yield(.unknown(Self.claudeContentBlockStop()))
    }

    static func planItemsMarkdown(_ items: [TodoItem]) -> String {
        guard !items.isEmpty else { return "" }
        return items.enumerated().map { index, item in
            let suffix: String
            switch item.status {
            case .completed: suffix = " *(completed)*"
            case .inProgress: suffix = " *(in progress)*"
            case .pending: suffix = ""
            }
            return "\(index + 1). \(item.content)\(suffix)"
        }.joined(separator: "\n")
    }

    func handleServerRequest(
        requestId: String,
        method: String,
        object: [String: JSONValue],
        activeThreadId: String?,
        permissionMode: PermissionMode,
        planMode: Bool,
        permissionServer: PermissionServer,
        stdin: FileHandle
    ) async throws {
        let params = object["params"]?.objectValue ?? [:]
        switch method {
        case "item/commandExecution/requestApproval",
             "item/fileChange/requestApproval",
             "request/approval":
            // Belt-and-suspenders: even though we set approvalPolicy on thread/start,
            // older codex versions may still escalate. Auto-accept when the user picked
            // .auto or .bypassPermissions and we're not in plan mode.
            if !planMode, permissionMode == .auto || permissionMode == .bypassPermissions {
                try Self.writeJSONLine(Self.response(id: requestId, result: [
                    "decision": .string("accept")
                ]), to: stdin)
                return
            }
            let toolUseId = Self.firstString(in: params, keys: ["itemId", "callId", "id"]) ?? requestId
            let command = Self.firstString(in: params, keys: ["command", "cmd"])
            let toolName = command == nil ? "Edit" : "Bash"
            var input = params
            if let command { input["command"] = .string(command) }
            let decision = await permissionServer.requestDecision(
                toolUseId: toolUseId,
                sessionId: activeThreadId,
                toolName: toolName,
                toolInput: input,
                mode: permissionMode
            )
            let approved = decision == .allow || {
                if case .allowAlwaysCommand = decision { return true }
                if case .allowSessionTool = decision { return true }
                if case .allowAndSetMode = decision { return true }
                return false
            }()
            try Self.writeJSONLine(Self.response(id: requestId, result: [
                "decision": .string(approved ? "accept" : "reject")
            ]), to: stdin)
        case "userInput/request":
            let toolUseId = Self.firstString(in: params, keys: ["itemId", "callId", "id"]) ?? requestId
            let decision = await permissionServer.requestDecision(
                toolUseId: toolUseId,
                sessionId: activeThreadId,
                toolName: "AskUserQuestion",
                toolInput: params,
                mode: permissionMode
            )
            try Self.writeJSONLine(Self.response(id: requestId, result: [
                "decision": .string(decision == .allow ? "accept" : "reject")
            ]), to: stdin)
        default:
            try Self.writeJSONLine(Self.response(id: requestId, result: [:]), to: stdin)
        }
    }
}
