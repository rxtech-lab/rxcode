import Foundation
import RxCodeCore
import os

actor CodexAppServer {
    enum CodexError: LocalizedError {
        case binaryNotFound
        case versionCheckFailed(String)
        case spawnFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Could not find the codex CLI binary."
            case .versionCheckFailed(let detail):
                return "Version check failed: \(detail)"
            case .spawnFailed(let detail):
                return "Failed to spawn codex app-server: \(detail)"
            }
        }
    }

    private struct RunningProcess {
        let process: Process
        let stdin: FileHandle
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.claudework",
        category: "CodexAppServer"
    )
    private var running: [UUID: RunningProcess] = [:]
    private var stderrBuffers: [UUID: String] = [:]
    private var cachedShellPath: String?
    private var cachedRateLimits: RateLimitUsage?
    private var cachedRateLimitsAt: Date?
    private var rateLimitsFetchTask: Task<RateLimitUsage?, Never>?
    private let rateLimitsCacheTTL: TimeInterval = 300
    private var notificationMethodCounts: [String: Int] = [:]
    /// Reference to the permission server for in-band permission requests.
    /// Wired once at app init; the `AgentBackend.send(_:)` adapter pulls it
    /// from here so callers don't have to pass it on every turn.
    private weak var permissionServer: PermissionServer?

    func setPermissionServer(_ server: PermissionServer) {
        self.permissionServer = server
    }

    private static var candidatePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.nvm/versions/node",
        ]
    }

    func findCodexBinary() async -> String? {
        let fm = FileManager.default
        for path in Self.candidatePaths {
            if path.hasSuffix("/node") {
                if let found = findNvmCodexBinary(root: path) { return found }
                continue
            }
            let resolved = (path as NSString).resolvingSymlinksInPath
            if fm.fileExists(atPath: resolved) && fm.isExecutableFile(atPath: path) {
                logger.info("Found codex binary at \(path, privacy: .public)")
                return path
            }
        }

        do {
            let output = try await runShellCommand("/bin/zsh", arguments: ["-ilc", "whence -p codex"])
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, fm.isExecutableFile(atPath: path) {
                logger.info("Found codex binary via shell at \(path, privacy: .public)")
                return path
            }
        } catch {
            logger.warning("Shell fallback failed while locating codex: \(error.localizedDescription)")
        }
        return nil
    }

    func checkVersion() async throws -> String {
        guard let binary = await findCodexBinary() else { throw CodexError.binaryNotFound }
        let output = try await runShellCommand(binary, arguments: ["--version"])
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw CodexError.versionCheckFailed("Empty version output") }
        return version
    }

    func fetchModels() async -> [AgentModel] {
        guard let binary = await findCodexBinary() else {
            logger.warning("Skipping Codex model fetch because no codex binary was found")
            return []
        }
        do {
            let streamId = UUID()
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: nil)
            defer { finalize(streamId: streamId) }
            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)
            try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
            try Self.writeJSONLine(Self.request(id: 2, method: "model/list", params: ["includeHidden": .bool(false)]), to: handles.stdin)

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard let object = Self.decodeObject(line),
                      Self.idString(object["id"]) == "2",
                      let result = object["result"] else { continue }
                let models = Self.parseModels(from: result)
                logger.info("Codex app-server model/list returned \(models.count) models")
                if !models.isEmpty { return models }
                logger.warning("Codex app-server model/list returned no parseable models; trying codex debug models")
                break
            }
        } catch {
            logger.warning("Codex model/list failed: \(error.localizedDescription)")
        }
        let debugModels = await fetchModelsFromDebugCommand(binary: binary)
        if !debugModels.isEmpty {
            logger.info("Codex debug models returned \(debugModels.count) models")
        } else {
            logger.warning("Codex debug models returned no parseable models; UI will use built-in fallback models")
        }
        return debugModels
    }

    func fetchRateLimits(forceRefresh: Bool = false) async -> RateLimitUsage? {
        if !forceRefresh,
           let cachedRateLimits,
           let cachedRateLimitsAt,
           Date().timeIntervalSince(cachedRateLimitsAt) < rateLimitsCacheTTL {
            return cachedRateLimits
        }

        if let rateLimitsFetchTask {
            return await rateLimitsFetchTask.value ?? cachedRateLimits
        }

        let task = Task { await self.fetchRateLimitsUncached() }
        rateLimitsFetchTask = task
        let usage = await task.value
        rateLimitsFetchTask = nil

        if let usage {
            cachedRateLimits = usage
            cachedRateLimitsAt = Date()
            return usage
        }
        return cachedRateLimits
    }

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

    private func fetchRateLimitsUncached() async -> RateLimitUsage? {
        guard let binary = await findCodexBinary() else {
            logger.warning("Skipping Codex rate-limit fetch because no codex binary was found")
            return nil
        }
        do {
            let streamId = UUID()
            let handles = try await spawnAppServer(binary: binary, streamId: streamId, cwd: nil)
            defer { finalize(streamId: streamId) }
            try Self.writeJSONLine(Self.request(id: 1, method: "initialize", params: initializeParams()), to: handles.stdin)
            try Self.writeJSONLine(Self.notification(method: "initialized", params: [:]), to: handles.stdin)
            try Self.writeJSONLine(Self.request(id: 2, method: "account/rateLimits/read", params: .null), to: handles.stdin)

            for try await line in handles.stdout.fileHandleForReading.bytes.lines {
                guard let object = Self.decodeObject(line) else { continue }

                if let requestId = Self.idString(object["id"]), object["method"] != nil {
                    try Self.writeJSONLine(Self.response(id: requestId, result: [:]), to: handles.stdin)
                    continue
                }

                if Self.idString(object["id"]) == "2", let result = object["result"] {
                    let usage = Self.parseCodexRateLimits(from: result)
                    if let usage {
                        logger.info("Codex rate limits 5h=\(usage.fiveHourPercent)% 24h=\(usage.twentyFourHourPercent ?? 0)%")
                    } else {
                        logger.warning("Codex account/rateLimits/read returned no parseable limits")
                    }
                    return usage
                }

                if object["method"]?.stringValue == "account/rateLimits/updated",
                   let params = object["params"] {
                    return Self.parseCodexRateLimits(from: params)
                }
            }
        } catch {
            logger.warning("Codex rate-limit fetch failed: \(error.localizedDescription)")
        }
        return nil
    }

    private func fetchModelsFromDebugCommand(binary: String) async -> [AgentModel] {
        do {
            let output = try await runShellCommand(binary, arguments: ["debug", "models"])
            guard let value = Self.decodeJSONValue(output) else {
                logger.warning("Could not decode codex debug models output as JSON")
                return []
            }
            return Self.parseModels(from: value)
        } catch {
            logger.warning("Codex debug models failed: \(error.localizedDescription)")
            return []
        }
    }

    func send(
        streamId: UUID,
        prompt: String,
        cwd: String,
        threadId: String?,
        model: String?,
        permissionMode: PermissionMode,
        planMode: Bool,
        mcpConfigOverrides: [String] = [],
        permissionServer: PermissionServer
    ) -> AsyncStream<StreamEvent> {
        AsyncStream<StreamEvent> { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runTurn(
                    streamId: streamId,
                    prompt: prompt,
                    cwd: cwd,
                    threadId: threadId,
                    model: model,
                    permissionMode: permissionMode,
                    planMode: planMode,
                    mcpConfigOverrides: mcpConfigOverrides,
                    permissionServer: permissionServer,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.finalize(streamId: streamId) }
            }
        }
    }

    func finalize(streamId: UUID) {
        guard let entry = running.removeValue(forKey: streamId) else { return }
        try? entry.stdin.close()
        if entry.process.isRunning {
            entry.process.terminate()
        }
    }

    func cancel(streamId: UUID) {
        finalize(streamId: streamId)
    }

    func consumeStderr(for streamId: UUID) -> String? {
        let value = stderrBuffers.removeValue(forKey: streamId)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func runTurn(
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
                            ? threadStartParams(threadId: activeThreadId, cwd: cwd, permissionMode: permissionMode, planMode: planMode)
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

    private func handleNotification(
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

    private func emitToolStart(item: [String: JSONValue], continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let name = toolName(from: item), name != "message" else { return }
        let id = Self.firstString(in: item, keys: ["id", "itemId", "callId"]) ?? UUID().uuidString
        let input = item["input"]?.objectValue ?? item["arguments"]?.objectValue ?? item
        continuation.yield(.unknown(Self.claudeToolStart(id: id, name: name)))
        continuation.yield(.unknown(Self.claudeInputDelta(input)))
        continuation.yield(.unknown(Self.claudeContentBlockStop()))
    }

    private func emitToolCompletion(item: [String: JSONValue], continuation: AsyncStream<StreamEvent>.Continuation) {
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
    private func emitSynthesizedExitPlanMode(
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

    private static func planItemsMarkdown(_ items: [TodoItem]) -> String {
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

    private func handleServerRequest(
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

    private func initializeParams() -> [String: JSONValue] {
        [
            "clientInfo": .object([
                "name": .string("RxCode"),
                "title": .string("RxCode"),
                "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
            ]),
            "capabilities": .object([:])
        ]
    }

    private func threadParams(threadId: String?, cwd: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let threadId { params["threadId"] = .string(threadId) }
        return params
    }

    private func threadStartParams(threadId: String?, cwd: String, permissionMode: PermissionMode, planMode: Bool) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let threadId { params["threadId"] = .string(threadId) }
        params["approvalPolicy"] = .string(Self.codexApprovalPolicy(permissionMode: permissionMode, planMode: planMode))
        params["sandbox"] = .string(Self.codexSandboxMode(permissionMode: permissionMode, planMode: planMode))
        if planMode {
            params["developerInstructions"] = .string(Self.planModeInstructions)
        }
        return params
    }

    private func turnParams(threadId: String, prompt: String, cwd: String, model: String?, permissionMode: PermissionMode, planMode: Bool) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "threadId": .string(threadId),
            "cwd": .string(cwd),
            "input": .array([
                .object(["type": .string("text"), "text": .string(prompt)])
            ])
        ]
        if let model { params["model"] = .string(model) }
        params["approvalPolicy"] = .string(Self.codexApprovalPolicy(permissionMode: permissionMode, planMode: planMode))
        params["sandboxPolicy"] = Self.codexSandboxPolicy(permissionMode: permissionMode, planMode: planMode)
        return params
    }

    private static let planModeInstructions = """
    Plan mode is enabled. Produce a clear, step-by-step plan using the update_plan tool. \
    Do not modify files; do not run commands that mutate state. \
    Read-only inspection is allowed. End with a concise summary of the proposed plan and \
    wait for the user to disable plan mode before making changes.
    """

    private static func codexApprovalPolicy(permissionMode: PermissionMode, planMode: Bool) -> String {
        if planMode { return "on-request" }
        switch permissionMode {
        case .default, .plan: return "untrusted"
        case .acceptEdits, .auto: return "on-request"
        case .bypassPermissions: return "never"
        }
    }

    private static func codexSandboxMode(permissionMode: PermissionMode, planMode: Bool) -> String {
        if planMode { return "read-only" }
        switch permissionMode {
        case .bypassPermissions: return "danger-full-access"
        default: return "workspace-write"
        }
    }

    private static func codexSandboxPolicy(permissionMode: PermissionMode, planMode: Bool) -> JSONValue {
        if planMode {
            return .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        }
        switch permissionMode {
        case .bypassPermissions:
            return .object(["type": .string("dangerFullAccess")])
        default:
            return .object(["type": .string("workspaceWrite")])
        }
    }

    private func spawnAppServer(binary: String, streamId: UUID, cwd: String?, configOverrides: [String] = []) async throws -> (process: Process, stdin: FileHandle, stdout: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--listen", "stdio://"] + configOverrides
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = await resolvedEnvironment()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw CodexError.spawnFailed(error.localizedDescription)
        }

        let stdinHandle = stdin.fileHandleForWriting
        running[streamId] = RunningProcess(process: process, stdin: stdinHandle)
        readStderr(stderr, streamId: streamId)
        return (process, stdinHandle, stdout)
    }

    private func readStderr(_ stderr: Pipe, streamId: UUID) {
        Task.detached { [weak self] in
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            await self?.appendStderr(text, streamId: streamId)
        }
    }

    private func appendStderr(_ text: String, streamId: UUID) {
        stderrBuffers[streamId, default: ""] += text
    }

    private func findNvmCodexBinary(root: String) -> String? {
        let fm = FileManager.default
        guard let versions = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for version in versions.sorted(by: >) {
            let candidate = "\(root)/\(version)/bin/codex"
            let resolved = (candidate as NSString).resolvingSymlinksInPath
            if fm.fileExists(atPath: resolved) && fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func resolvedEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let cachedShellPath {
            env["PATH"] = cachedShellPath
            return env
        }
        let rawShellPath = try? await runShellCommand("/bin/zsh", arguments: ["-ilc", "print -rn -- $PATH"], injectPath: false)
        let shellPath = rawShellPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let shellPath, !shellPath.isEmpty {
            cachedShellPath = shellPath
            env["PATH"] = shellPath
        }
        return env
    }

    private func runShellCommand(_ executable: String, arguments: [String], injectPath: Bool = true) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if injectPath {
            process.environment = await resolvedEnvironment()
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CodexError.versionCheckFailed(err.isEmpty ? out : err)
        }
        return out
    }

    private func cleanTitle(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !cleaned.isEmpty else { return nil }

        let lower = cleaned.lowercased()
        let errorPrefixes = ["api error", "error:", "execution error", "request failed", "codex error"]
        guard !errorPrefixes.contains(where: { lower.hasPrefix($0) }) else { return nil }
        return String(cleaned.prefix(80))
    }

    private func toolName(from item: [String: JSONValue]) -> String? {
        if let type = Self.firstString(in: item, keys: ["type", "kind"]) {
            let normalizedType = type.lowercased()
            if normalizedType.contains("command") { return "Bash" }
            if normalizedType.contains("file") || normalizedType.contains("patch") { return "Edit" }
            if normalizedType.contains("message") { return "message" }
            return type
        }
        guard let name = Self.firstString(in: item, keys: ["name", "toolName"]) else { return nil }
        return name.lowercased().contains("message") ? "message" : name
    }

    private static func parseModels(from value: JSONValue) -> [AgentModel] {
        let root = value.objectValue
        let rawModels = root?["data"]?.arrayValue ?? root?["models"]?.arrayValue ?? root?["items"]?.arrayValue ?? value.arrayValue ?? []
        return rawModels.compactMap { entry in
            if let id = entry.stringValue {
                return AgentModel(provider: .codex, id: id, displayName: AppStateModelFormatter.codexDisplayName(id), description: "Codex model served by the Codex app-server.")
            }
            guard let object = entry.objectValue,
                  let id = firstString(in: object, keys: ["id", "slug", "model", "name"]) else { return nil }
            if object["hidden"]?.boolValue == true || object["visibility"]?.stringValue == "hidden" {
                return nil
            }
            let displayName = firstString(in: object, keys: ["displayName", "display_name", "name"]) ?? AppStateModelFormatter.codexDisplayName(id)
            let description = firstString(in: object, keys: ["description", "detail"]) ?? "Codex model served by the Codex app-server."
            return AgentModel(provider: .codex, id: id, displayName: displayName, description: description)
        }
    }

    private static func request(id: Int, method: String, params: [String: JSONValue]) -> JSONValue {
        request(id: id, method: method, params: .object(params))
    }

    private static func request(id: Int, method: String, params: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
    }

    private static func response(id: String, result: [String: JSONValue]) -> JSONValue {
        let idValue = Double(id).map(JSONValue.number) ?? .string(id)
        return .object(["jsonrpc": .string("2.0"), "id": idValue, "result": .object(result)])
    }

    private static func notification(method: String, params: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])
    }

    private static func writeJSONLine(_ value: JSONValue, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0A]))
    }

    private static func decodeObject(_ line: String) -> [String: JSONValue]? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value.objectValue
    }

    private static func decodeJSONValue(_ text: String) -> JSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func idString(_ value: JSONValue?) -> String? {
        if let s = value?.stringValue { return s }
        if let n = value?.numberValue {
            if n.rounded() == n { return String(Int(n)) }
            return String(n)
        }
        return nil
    }

    private static func threadId(from value: JSONValue) -> String? {
        if let object = value.objectValue {
            if let id = firstString(in: object, keys: ["threadId", "thread_id", "id"]) { return id }
            if let nested = object["thread"]?.objectValue {
                return firstString(in: nested, keys: ["threadId", "thread_id", "id"])
            }
        }
        return value.stringValue
    }

    private static func firstString(in object: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key]?.stringValue { return value }
            if let number = object[key]?.numberValue { return String(number) }
        }
        return nil
    }

    private struct CodexRateLimitWindow {
        let percent: Double
        let resetsAt: Date?
        let durationMinutes: Int?
    }

    private static func parseCodexRateLimits(from value: JSONValue) -> RateLimitUsage? {
        guard let snapshot = codexRateLimitSnapshot(from: value) else { return nil }
        let windows = [
            parseCodexRateLimitWindow(snapshot["primary"]),
            parseCodexRateLimitWindow(snapshot["secondary"])
        ].compactMap { $0 }

        guard !windows.isEmpty else { return nil }
        let fiveHour = windows.first { $0.durationMinutes == 300 } ?? windows.first
        let twentyFourHour = windows.first { $0.durationMinutes == 1_440 }
            ?? windows.first { $0.durationMinutes != fiveHour?.durationMinutes }
            ?? windows.dropFirst().first

        return RateLimitUsage(
            fiveHourPercent: fiveHour?.percent ?? 0,
            sevenDayPercent: 0,
            twentyFourHourPercent: twentyFourHour?.percent,
            fiveHourResetsAt: fiveHour?.resetsAt,
            sevenDayResetsAt: nil,
            twentyFourHourResetsAt: twentyFourHour?.resetsAt
        )
    }

    private static func codexRateLimitSnapshot(from value: JSONValue) -> [String: JSONValue]? {
        guard let object = value.objectValue else { return nil }

        if let byLimitId = object["rateLimitsByLimitId"]?.objectValue {
            if let codex = byLimitId["codex"]?.objectValue {
                return codex
            }
            for snapshot in byLimitId.values.compactMap(\.objectValue) {
                if firstString(in: snapshot, keys: ["limitId", "limit_id"]) == "codex" {
                    return snapshot
                }
            }
        }

        if let rateLimits = object["rateLimits"]?.objectValue {
            return rateLimits
        }

        if object["primary"] != nil || object["secondary"] != nil {
            return object
        }

        return nil
    }

    private static func parseCodexRateLimitWindow(_ value: JSONValue?) -> CodexRateLimitWindow? {
        guard let object = value?.objectValue else { return nil }
        let percent = firstDouble(in: object, keys: ["usedPercent", "used_percent", "utilization"])
        let duration = firstOptionalInt(in: object, keys: ["windowDurationMins", "window_duration_mins", "windowMinutes"])
        return CodexRateLimitWindow(
            percent: percent,
            resetsAt: parseUnixOrISODate(object["resetsAt"] ?? object["resets_at"]),
            durationMinutes: duration
        )
    }

    private static func firstDouble(in object: [String: JSONValue], keys: [String]) -> Double {
        for key in keys {
            if let value = object[key]?.numberValue { return value }
            if let value = object[key]?.stringValue, let doubleValue = Double(value) { return doubleValue }
        }
        return 0
    }

    private static func firstOptionalInt(in object: [String: JSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key]?.numberValue { return Int(value) }
            if let value = object[key]?.stringValue, let intValue = Int(value) { return intValue }
        }
        return nil
    }

    private static func parseUnixOrISODate(_ value: JSONValue?) -> Date? {
        if let number = value?.numberValue {
            let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value?.stringValue else { return nil }
        if let number = Double(string) {
            let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
            return Date(timeIntervalSince1970: seconds)
        }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func usageInfo(from object: [String: JSONValue]) -> UsageInfo? {
        let params = object["params"]?.objectValue ?? object
        let usageKeys = ["usage", "tokenUsage", "token_usage", "totalUsage", "total_usage", "metrics"]
        let usage = firstObject(in: params, keys: [
            "usage", "tokenUsage", "token_usage", "totalUsage", "total_usage", "metrics"
        ]) ?? firstNestedObject(in: .object(params), keys: usageKeys) ?? params

        var inputTokens = firstInt(in: usage, keys: [
            "input_tokens", "inputTokens", "prompt_tokens", "promptTokens"
        ])
        var outputTokens = firstInt(in: usage, keys: [
            "output_tokens", "outputTokens", "completion_tokens", "completionTokens"
        ])
        outputTokens += firstInt(in: usage, keys: [
            "reasoning_output_tokens", "reasoningOutputTokens"
        ])
        let cacheCreationTokens = firstInt(in: usage, keys: [
            "cache_creation_input_tokens", "cacheCreationInputTokens", "cacheWriteInputTokens",
            "cached_creation_tokens", "cachedCreationTokens"
        ])
        let explicitCacheReadTokens = firstInt(in: usage, keys: [
            "cache_read_input_tokens", "cacheReadInputTokens", "cached_input_tokens",
            "cachedInputTokens", "cache_read_tokens", "cacheReadTokens"
        ])
        let cacheReadTokens = explicitCacheReadTokens > 0 ? explicitCacheReadTokens : nestedInputCacheReadTokens(in: usage)

        let total = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        let totalTokens = firstInt(in: usage, keys: ["total_tokens", "totalTokens"])
        if total == 0, totalTokens > 0 {
            inputTokens = totalTokens
        }

        guard inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens > 0 else {
            return nil
        }
        return UsageInfo(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationInputTokens: cacheCreationTokens,
            cacheReadInputTokens: cacheReadTokens
        )
    }

    private static func liveTokenUsage(from params: [String: JSONValue]) -> UsageInfo? {
        guard let outputTokens = tokenUsageOutputTokens(from: params),
              outputTokens > 0 else { return nil }
        return UsageInfo(
            inputTokens: 0,
            outputTokens: outputTokens,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0
        )
    }

    private static func tokenUsageOutputTokens(from params: [String: JSONValue]) -> Int? {
        let usage = tokenUsageSummary(from: params)
        let outputTokens = firstInt(in: usage, keys: ["outputTokens", "output_tokens"])
        let reasoningOutputTokens = firstInt(in: usage, keys: [
            "reasoningOutputTokens", "reasoning_output_tokens"
        ])
        let total = outputTokens + reasoningOutputTokens
        return total > 0 ? total : nil
    }

    private static func tokenUsageTokensUsed(from params: [String: JSONValue]) -> Int? {
        let usage = tokenUsageSummary(from: params)
        let tokensUsed = firstInt(in: usage, keys: [
            "tokensUsed", "tokens_used", "totalTokens", "total_tokens",
            "total", "used", "currentTokens", "current_tokens"
        ])
        return tokensUsed > 0 ? tokensUsed : nil
    }

    private static func tokenUsageTokenBudget(from params: [String: JSONValue]) -> Int? {
        let usage = firstObject(in: params, keys: ["tokenUsage", "token_usage"])
            ?? firstNestedObject(in: .object(params), keys: ["tokenUsage", "token_usage"])
            ?? params
        let tokenBudget = firstInt(in: usage, keys: [
            "tokenBudget", "token_budget", "modelContextWindow", "model_context_window"
        ])
        return tokenBudget > 0 ? tokenBudget : nil
    }

    private static func tokenUsageSummary(from params: [String: JSONValue]) -> [String: JSONValue] {
        let usage = firstObject(in: params, keys: ["tokenUsage", "token_usage"])
            ?? firstNestedObject(in: .object(params), keys: ["tokenUsage", "token_usage"])
            ?? params
        return firstObject(in: usage, keys: ["last"])
            ?? firstObject(in: usage, keys: ["total"])
            ?? usage
    }

    private static func firstObject(in object: [String: JSONValue], keys: [String]) -> [String: JSONValue]? {
        for key in keys {
            if let value = object[key]?.objectValue { return value }
        }
        return nil
    }

    private static func firstNestedObject(in value: JSONValue, keys: [String]) -> [String: JSONValue]? {
        if let object = value.objectValue {
            if let direct = firstObject(in: object, keys: keys) { return direct }
            for nested in object.values {
                if let found = firstNestedObject(in: nested, keys: keys) { return found }
            }
        }
        if let array = value.arrayValue {
            for nested in array {
                if let found = firstNestedObject(in: nested, keys: keys) { return found }
            }
        }
        return nil
    }

    private static func firstInt(in object: [String: JSONValue], keys: [String]) -> Int {
        for key in keys {
            if let value = object[key]?.numberValue { return Int(value) }
            if let value = object[key]?.stringValue, let intValue = Int(value) { return intValue }
        }
        return 0
    }

    private static func nestedInputCacheReadTokens(in usage: [String: JSONValue]) -> Int {
        guard let details = firstObject(in: usage, keys: [
            "input_tokens_details", "inputTokensDetails", "prompt_tokens_details", "promptTokensDetails"
        ]) else { return 0 }
        return firstInt(in: details, keys: [
            "cached_tokens", "cachedTokens", "cache_read_input_tokens", "cacheReadInputTokens"
        ])
    }

    private static func usageMessageId(from params: [String: JSONValue], fallback: String?) -> String {
        firstString(in: params, keys: [
            "messageId", "message_id", "responseId", "response_id",
            "turnId", "turn_id", "itemId", "item_id", "id"
        ]) ?? fallback ?? "codex-turn"
    }

    private static func claudeTextDelta(_ text: String) -> String {
        jsonString([
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": text]
        ])
    }

    private static func claudeThinkingDelta(_ text: String) -> String {
        jsonString([
            "type": "content_block_delta",
            "delta": ["type": "thinking_delta", "thinking": text]
        ])
    }

    private static func claudeToolStart(id: String, name: String) -> String {
        jsonString([
            "type": "content_block_start",
            "content_block": ["type": "tool_use", "id": id, "name": name]
        ])
    }

    private static func claudeInputDelta(_ input: [String: JSONValue]) -> String {
        let data = (try? JSONEncoder().encode(JSONValue.object(input))) ?? Data("{}".utf8)
        let inputText = String(data: data, encoding: .utf8) ?? "{}"
        return jsonString([
            "type": "content_block_delta",
            "delta": ["type": "input_json_delta", "partial_json": inputText]
        ])
    }

    private static func claudeContentBlockStop() -> String {
        jsonString(["type": "content_block_stop"])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

private enum AppStateModelFormatter {
    nonisolated static func codexDisplayName(_ model: String) -> String {
        model
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                part.uppercased().hasPrefix("GPT") ? part.uppercased() : part.capitalized
            }
            .joined(separator: " ")
    }
}

// MARK: - AgentBackend Conformance

extension CodexAppServer: AgentBackend {
    nonisolated var provider: AgentProvider { .codex }
    nonisolated var staticCapabilities: CapabilitySet { AgentProvider.codex.staticCapabilities }

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        guard let permissionServer else {
            logger.error("[Codex] send called before setPermissionServer wired")
            return AsyncStream<StreamEvent> { c in
                c.yield(.user(UserMessage(
                    toolUseId: nil,
                    content: "Codex backend not initialized (missing permission server).",
                    isError: true
                )))
                c.yield(.result(ResultEvent(
                    durationMs: nil, totalCostUsd: nil,
                    sessionId: request.sessionId ?? request.clientSessionKey,
                    isError: true, totalTurns: nil, usage: nil, contextWindow: nil
                )))
                c.finish()
            }
        }
        return send(
            streamId: request.streamId,
            prompt: request.prompt,
            cwd: request.cwd,
            threadId: request.sessionId,
            model: request.model,
            permissionMode: request.permissionMode,
            planMode: request.planMode,
            mcpConfigOverrides: request.mcpCodexOverrides,
            permissionServer: permissionServer
        )
    }
}
