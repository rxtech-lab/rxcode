import Foundation
import RxCodeCore

/// Account-authenticated text chat. Each request replays the active thread's
/// transcript because Flowcy does not store a server-side conversation.
actor FlowcyCloudBackend: AgentBackend {
    nonisolated let provider = AgentProvider.flowcy
    nonisolated let staticCapabilities: CapabilitySet = []
    static let productionURL = URL(string: "https://www.flowcy.dev/api/v1")!

    private let token: @Sendable (Bool) async -> String?
    private let baseURL: URL
    private let session: URLSession
    private var turns: [UUID: Task<Void, Never>] = [:]
    private var errors: [UUID: String] = [:]

    init(auth: RxAuthService) {
        self.init(baseURL: Self.productionURL) { await auth.accessToken(forceRefresh: $0) }
    }

    init(baseURL: URL, session: URLSession = .shared, token: @escaping @Sendable (Bool) async -> String?) {
        self.baseURL = baseURL
        self.session = session
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

    func reply(model: String?, prompt: String, history: [ChatMessage] = [],
               onText: @Sendable (String) -> Void = { _ in }) async throws -> String {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IDEToolError.invalidArguments("Enter a prompt to send to Flowcy.")
        }
        var messages: [JSONValue] = history.compactMap { message in
            guard !message.isError, !message.isCompactBoundary else { return nil }
            let text = message.content
            guard !text.isEmpty else { return nil }
            return .object(["role": .string(message.role.rawValue), "content": .string(text)])
        }
        messages.append(.object(["role": .string("user"), "content": .string(prompt)]))
        var fields: [String: JSONValue] = ["messages": .array(messages), "tools": .array([])]
        if let model, model != AgentModel.flowcyDefaultID { fields["modelId"] = .string(model) }
        let body = try JSONEncoder().encode(fields)
        guard messages.count <= 100, body.count <= 1_000_000 else {
            throw IDEToolError.handlerFailed("This conversation exceeds Flowcy’s request limit. Start a new chat or shorten your prompt.")
        }
        let (bytes, response) = try await request("agent/chat", body: body)
        guard response.mimeType == "application/x-ndjson" else { throw IDEToolError.handlerFailed("Invalid Flowcy stream.") }
        var result = ""
        var byteCount = 0
        var finished = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty else { continue }
            guard !finished, line.utf8.count <= 1_000_000 else { throw IDEToolError.handlerFailed("Invalid Flowcy stream.") }
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            switch event["type"]?.stringValue {
            case "text":
                guard let text = event["text"]?.stringValue else { throw IDEToolError.handlerFailed("Invalid Flowcy text event.") }
                byteCount += text.utf8.count
                guard byteCount <= 1_000_000 else { throw IDEToolError.handlerFailed("Flowcy response is too large.") }
                result += text
                onText(text)
            case "finish": finished = true
            default: throw IDEToolError.handlerFailed("Flowcy could not complete this response.")
            }
        }
        try Task.checkCancellation()
        guard finished else { throw IDEToolError.handlerFailed("Flowcy response was interrupted.") }
        return result
    }

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()
        let task = Task {
            defer {
                turns.removeValue(forKey: request.streamId)
                continuation.finish()
            }
            let sessionId = request.sessionId ?? UUID().uuidString
            continuation.yield(.system(SystemEvent(subtype: "init", sessionId: sessionId, tools: [],
                                                    model: request.model, claudeCodeVersion: nil)))
            do {
                _ = try await reply(model: request.model, prompt: request.prompt, history: request.history) { delta in
                    continuation.yield(.textDelta(delta))
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The stream consumer reads error details after finalizing the turn.
                if errors.count >= 32, let oldest = errors.keys.first { errors.removeValue(forKey: oldest) }
                errors[request.streamId] = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            continuation.yield(.result(ResultEvent(durationMs: nil, totalCostUsd: nil, sessionId: sessionId,
                                                   isError: errors[request.streamId] != nil, totalTurns: 1,
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
