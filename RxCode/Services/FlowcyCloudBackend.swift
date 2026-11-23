import Foundation
import RxCodeCore

/// Account-authenticated model turns. Flowcy is stateless, so each request
/// carries the transcript, including completed desktop tool calls and results.
actor FlowcyCloudBackend: AgentBackend {
    nonisolated let provider = AgentProvider.flowcy
    nonisolated let staticCapabilities = AgentProvider.flowcy.staticCapabilities
    static let productionURL = URL(string: "https://www.flowcy.dev/api/v1")!

    private let token: @Sendable (Bool) async -> String?
    private let baseURL: URL
    private let session: URLSession
    private let permission: PermissionServer
    private var turns: [UUID: Task<Void, Never>] = [:]
    private var errors: [UUID: String] = [:]

    private enum RequestError: LocalizedError {
        case invalidChatRequest
        var errorDescription: String? { "Flowcy request failed (HTTP 400)." }
    }

    init(auth: RxAuthService, permission: PermissionServer) {
        self.init(baseURL: Self.productionURL, permission: permission) { await auth.accessToken(forceRefresh: $0) }
    }

    init(baseURL: URL, session: URLSession = .shared, permission: PermissionServer,
         token: @escaping @Sendable (Bool) async -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.permission = permission
        self.token = token
    }

    private func request(_ path: String, body: Data? = nil) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        for refresh in [false, true] {
            try Task.checkCancellation()
            guard let token = await token(refresh) else {
                throw IDEToolError.handlerFailed("Sign in to Flowcy in Settings to use Cloud Chat.")
            }
            var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 90)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(body == nil ? "application/json" : "application/x-ndjson", forHTTPHeaderField: "Accept")
            if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw IDEToolError.handlerFailed("Invalid Flowcy response.") }
            switch http.statusCode {
            case 200..<300: return (bytes, http)
            case 400: throw RequestError.invalidChatRequest
            case 401 where !refresh: continue
            case 401: throw IDEToolError.handlerFailed("Flowcy sign-in expired. Sign in again in Settings.")
            case 429: throw IDEToolError.handlerFailed("Flowcy usage or request limit reached. Wait for the allowance to reset or select a less expensive model.")
            default: throw IDEToolError.handlerFailed("Flowcy request failed (HTTP \(http.statusCode)).")
            }
        }
        throw IDEToolError.handlerFailed("Flowcy sign-in expired.")
    }

    func fetchModels() async throws -> [AgentModel] {
        nonisolated struct Catalog: Decodable {
            struct Model: Decodable { let modelId: String; let alias: String }
            let models: [Model]
        }
        let (bytes, _) = try await request("agent/models")
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 4_000_000 else { throw IDEToolError.handlerFailed("Flowcy model catalog is too large.") }
        }
        return try JSONDecoder().decode(Catalog.self, from: data).models.map {
            AgentModel(provider: .flowcy, id: $0.modelId, displayName: $0.alias)
        }
    }

    /// One-shot cloudChat MCP requests have no workspace or local execution authority.
    func reply(model: String?, prompt: String) async throws -> String {
        let messages = try transcript(history: [], prompt: prompt)
        return try await modelStep(model: model, messages: messages, terminalEnabled: false) { _ in }.text
    }

    private struct ModelStep {
        var text = ""
        var calls: [FlowcyToolCall] = []

        var assistantMessage: JSONValue {
            var content: [JSONValue] = []
            if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
            return .object(["role": .string("assistant"), "content": .array(content + calls.map(\.callPart))])
        }
    }

    private func transcript(history: [ChatMessage], prompt: String) throws -> [JSONValue] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("Enter a prompt to send to Flowcy.")
        }
        var messages: [JSONValue] = []
        for message in history where !message.isError && !message.isCompactBoundary {
            var step = ModelStep()
            var results: [JSONValue] = []
            func flush() {
                if !results.isEmpty {
                    messages.append(step.assistantMessage)
                    messages.append(.object(["role": .string("tool"), "content": .array(results)]))
                } else if !step.text.isEmpty {
                    messages.append(.object(["role": .string(message.role.rawValue), "content": .string(step.text)]))
                }
                step = ModelStep()
                results.removeAll()
            }
            for block in message.blocks {
                if let text = block.text, !text.isEmpty {
                    if !results.isEmpty { flush() }
                    if !step.text.isEmpty { step.text += "\n\n" }
                    step.text += text
                } else if message.role == .assistant, let saved = block.toolCall, let output = saved.result,
                          let call = FlowcyToolCall(saved: saved) {
                    step.calls.append(call)
                    results.append(call.resultPart(output, isError: saved.isError))
                }
            }
            flush()
        }
        messages.append(.object(["role": .string("user"), "content": .string(prompt)]))
        return messages
    }

    private func modelStep(model: String?, messages: [JSONValue], terminalEnabled: Bool, questionEnabled: Bool = false,
                           onText: @Sendable (String) -> Void) async throws -> ModelStep {
        var tools = terminalEnabled ? [FlowcyToolCall.terminalDefinition] : []
        if questionEnabled { tools.append(FlowcyToolCall.questionDefinition) }
        var fields: [String: JSONValue] = ["messages": .array(messages), "tools": .array(tools)]
        if let model, model != AgentModel.flowcyDefaultID { fields["modelId"] = .string(model) }
        let body = try JSONEncoder().encode(fields)
        guard messages.count <= 100, body.count <= 1_000_000 else {
            throw IDEToolError.handlerFailed("This conversation exceeds Flowcy’s request limit. Start a new chat or shorten your prompt.")
        }
        let (bytes, response) = try await request("agent/chat", body: body)
        guard response.mimeType == "application/x-ndjson" else { throw IDEToolError.handlerFailed("Invalid Flowcy stream.") }
        var step = ModelStep()
        var byteCount = 0
        func countPayload(_ size: Int) throws {
            byteCount += size
            guard byteCount <= 1_000_000 else { throw IDEToolError.handlerFailed("Flowcy response is too large.") }
        }
        var finished = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty else { continue }
            guard !finished, line.utf8.count <= 1_000_000 else { throw IDEToolError.handlerFailed("Invalid Flowcy stream.") }
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            switch event["type"]?.stringValue {
            case "text":
                guard let text = event["text"]?.stringValue else { throw IDEToolError.handlerFailed("Invalid Flowcy text event.") }
                try countPayload(text.utf8.count)
                step.text += text
                onText(text)
            case "tool-call":
                guard let call = FlowcyToolCall(event: event, terminalEnabled: terminalEnabled, questionEnabled: questionEnabled) else {
                    throw IDEToolError.handlerFailed("Flowcy requested an unavailable or invalid tool.")
                }
                try countPayload(line.utf8.count)
                step.calls.append(call)
            case "finish": finished = true
            default: throw IDEToolError.handlerFailed("Flowcy could not complete this response.")
            }
        }
        try Task.checkCancellation()
        guard finished else { throw IDEToolError.handlerFailed("Flowcy response was interrupted.") }
        return step
    }

    private func run(_ request: BackendSendRequest, permissionSessionID: String, terminalEnabled: Bool,
                     into continuation: AsyncStream<StreamEvent>.Continuation) async throws -> Int {
        var messages = try transcript(history: request.history, prompt: request.prompt)
        var seen = Set<String>()
        var round = 1
        var questionEnabled = request.askUser != nil
        while true {
            let step: ModelStep
            do {
                step = try await modelStep(model: request.model, messages: messages, terminalEnabled: terminalEnabled,
                                           questionEnabled: questionEnabled) { continuation.yield(.textDelta($0)) }
            } catch RequestError.invalidChatRequest where questionEnabled && round == 1 {
                // Older deployments reject new tool declarations before starting inference.
                questionEnabled = false
                continue
            }
            if step.calls.isEmpty { return round }
            guard round < 8, seen.count + step.calls.count <= 32 else {
                throw IDEToolError.handlerFailed("Flowcy reached its tool-call limit. Send another message to continue.")
            }
            guard messages.count + 2 <= 100 else {
                throw IDEToolError.handlerFailed("This chat is too long to return a tool result to Flowcy. Start a new chat to continue.")
            }
            guard step.calls.allSatisfy({ seen.insert($0.id).inserted }) else {
                throw IDEToolError.handlerFailed("Flowcy returned a duplicate tool call.")
            }
            // Validate the complete model step before acting. A broken stream, including
            // a missing finish after a tool call, must never start a local command.
            var results: [JSONValue] = []
            for call in step.calls {
                try Task.checkCancellation()
                continuation.yield(.assistant(AssistantMessage(role: "assistant", content: [
                    .toolUse(id: call.localID(streamID: request.streamId), name: call.displayName, input: call.input),
                ])))
                let result = try await call.execute(request: request, sessionID: permissionSessionID, permission: permission)
                continuation.yield(.user(result))
                results.append(call.resultPart(result.content, isError: result.isError))
            }
            messages.append(step.assistantMessage)
            messages.append(.object(["role": .string("tool"), "content": .array(results)]))
            round += 1
        }
    }

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()
        let task = Task {
            defer {
                turns.removeValue(forKey: request.streamId)
                continuation.finish()
            }
            let isNewThread = request.clientSessionKey.hasPrefix("pending-")
            let sessionId = request.sessionId ?? UUID().uuidString
            let permissionSessionID = isNewThread ? sessionId : request.clientSessionKey
            let terminalEnabled = request.cwd.hasPrefix("/") && !request.planMode && request.permissionMode != .plan
            if terminalEnabled && sessionId != permissionSessionID {
                // A thread switched from another provider keeps its original UI and permission key.
                await permission.registerSession(sid: permissionSessionID, projectKey: request.cwd, mode: request.permissionMode)
            }
            var tools = terminalEnabled ? ["Bash"] : []
            if request.askUser != nil { tools.append(IDEToolRegistry.askUser.name) }
            continuation.yield(.system(SystemEvent(subtype: "init", sessionId: sessionId, tools: tools,
                                                    model: request.model, claudeCodeVersion: nil)))
            var rounds: Int?
            do {
                rounds = try await run(request, permissionSessionID: permissionSessionID,
                                       terminalEnabled: terminalEnabled, into: continuation)
            } catch {
                guard !Task.isCancelled else { return }
                // The stream consumer reads error details after finalizing the turn.
                if errors.count >= 32, let oldest = errors.keys.first { errors.removeValue(forKey: oldest) }
                errors[request.streamId] = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            continuation.yield(.result(ResultEvent(durationMs: nil, totalCostUsd: nil, sessionId: sessionId,
                                                   isError: errors[request.streamId] != nil, totalTurns: rounds,
                                                   usage: nil, contextWindow: nil)))
        }
        turns[request.streamId] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func cancel(streamId: UUID) {
        turns[streamId]?.cancel()
        errors.removeValue(forKey: streamId)
    }

    func finalize(streamId: UUID) { turns.removeValue(forKey: streamId) }

    func consumeStderr(for streamId: UUID) -> String? { errors.removeValue(forKey: streamId) }
}
