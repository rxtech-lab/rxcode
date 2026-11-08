import Foundation
import Observation
import RxCodeCore

/// Account-authenticated cloud chat. Local filesystem tools are not exposed by this transport.
@MainActor @Observable
final class FlowcyCloudChat {
    struct Model: Decodable, Identifiable { let modelId: String; let alias: String; var id: String { modelId } }
    struct Message: Identifiable { let id = UUID(); let role: String; var text: String }
    private(set) var models: [Model] = []
    private(set) var messages: [Message] = []
    var selectedModel: String?
    var error: String?
    private(set) var loading = false
    private(set) var streaming = false
    private let auth: RxAuthService
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var catalogGeneration = UUID()
    private var history: [[String: String]] = []
    init(auth: RxAuthService) { self.auth = auth }

    private var baseURL: URL {
        #if DEBUG
        URL(string: "http://localhost:3000/api/v1")!
        #else
        URL(string: "https://www.flowcy.dev/api/v1")!
        #endif
    }

    private func request(_ path: String, body: Data? = nil) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        for refresh in [false, true] {
            guard let token = await auth.accessToken(forceRefresh: refresh) else { throw Failure("Sign in to Flowcy in Settings first.") }
            var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 90)
            request.httpMethod = body == nil ? "GET" : "POST"
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure("Invalid Flowcy response.") }
            if http.statusCode == 401 && !refresh { continue }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 429 { throw Failure("Flowcy usage or request limit reached. Wait for the allowance to reset or select a less expensive model.") }
                throw Failure("Flowcy request failed (HTTP \(http.statusCode)).")
            }
            return (bytes, http)
        }
        throw Failure("Flowcy sign-in expired.")
    }

    func load() async {
        let current = UUID()
        catalogGeneration = current
        loading = true
        defer { if catalogGeneration == current { loading = false } }
        do {
            let (bytes, _) = try await request("agent/models")
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= 4_000_000 else { throw Failure("Model catalog is too large.") }
            }
            struct Catalog: Decodable { let models: [Model] }
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            try Task.checkCancellation()
            guard catalogGeneration == current else { return }
            models = catalog.models
            if !models.contains(where: { $0.id == selectedModel }) { selectedModel = models.first?.id }
            error = nil
        } catch is CancellationError { }
        catch {
            guard catalogGeneration == current, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func send(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !streaming, !prompt.isEmpty, let model = selectedModel else { return }
        guard history.count < 98 else { error = "Start a new chat to continue; this conversation has reached its message limit."; return }
        let current = UUID()
        generation = current
        streaming = true
        error = nil
        let input = history + [["role": "user", "content": prompt]]
        messages.append(Message(role: "user", text: prompt))
        messages.append(Message(role: "assistant", text: ""))
        let index = messages.count - 1
        operation = Task {
            defer { if generation == current { streaming = false; operation = nil } }
            do {
                let body = try JSONSerialization.data(withJSONObject: ["modelId": model, "messages": input, "tools": []] as [String: Any])
                let (bytes, response) = try await request("agent/chat", body: body)
                guard response.value(forHTTPHeaderField: "Content-Type")?.contains("application/x-ndjson") == true else { throw Failure("Invalid Flowcy stream.") }
                var finished = false
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard generation == current else { throw CancellationError() }
                    guard !line.isEmpty else { continue }
                    guard line.utf8.count <= 1_000_000, !finished else { throw Failure("Invalid Flowcy stream.") }
                    let event = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                    switch event["type"]?.stringValue {
                    case "text":
                        guard let text = event["text"]?.stringValue else { throw Failure("Invalid text event.") }
                        messages[index].text += text
                        guard messages[index].text.utf8.count <= 1_000_000 else { throw Failure("Response is too large.") }
                    case "finish": finished = true
                    default: throw Failure("Flowcy could not complete this response.")
                    }
                }
                guard finished else { throw Failure("Flowcy response was interrupted.") }
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                history = input + [["role": "assistant", "content": messages[index].text]]
            } catch is CancellationError { }
            catch { if generation == current { self.error = error.localizedDescription } }
        }
    }

    func stop() { generation = UUID(); operation?.cancel(); operation = nil; streaming = false }
    func clear() { stop(); history = []; messages = []; error = nil }
    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
