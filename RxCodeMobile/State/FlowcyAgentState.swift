import Foundation
import Observation
import RxCodeCore

struct FlowcyChatMessage: Codable, Identifiable {
    let id: UUID
    let role: String
    var text: String
    var toolCalls: [ToolCall]? = nil
    init(role: String, text: String) { id = UUID(); self.role = role; self.text = text }
}

struct FlowcyPendingTool: Identifiable {
    let id: String
    let tool: FlowcyTool
    let arguments: JSONValue
}

/// Chat lifetime is independent of tabs and the paired remote workspace.
@MainActor @Observable
final class FlowcyAgentState {
    private(set) var messages: [FlowcyChatMessage] = []
    private(set) var isStreaming = false
    private(set) var progress: String?
    var error: String?
    private(set) var canRetry = false
    private(set) var retryAt: Date?
    var pendingTool: FlowcyPendingTool?
    @ObservationIgnored private let api: FlowcyAPI
    init(api: FlowcyAPI? = nil) { self.api = api ?? FlowcyAPI() }

    @ObservationIgnored private var history: [JSONValue] = []
    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var performedWrite = false

    private struct Saved: Codable { let messages: [FlowcyChatMessage]; let history: [JSONValue] }
    private var file: URL? {
        guard let accountID else { return nil }
        let name = Data(accountID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FlowcyChat", isDirectory: true).appendingPathComponent(name + ".json")
    }

    func restore(accountID: String?) {
        guard accountID != self.accountID else { return }
        cancel()
        retryAt = nil
        error = nil
        self.accountID = accountID
        messages = []
        history = []
        guard let file, let data = try? Data(contentsOf: file), data.count <= 4_000_000,
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        messages = saved.messages
        history = saved.history
    }

    func newChat() {
        cancel()
        messages = []
        history = []
        error = nil
        persist()
        MobileHaptics.buttonTap()
    }

    func cancel() {
        if isStreaming { persist() }
        generation = UUID()
        run?.cancel()
        run = nil
        approve(false)
        isStreaming = false
        progress = nil
        canRetry = false
    }

    func approve(_ allowed: Bool) {
        pendingTool = nil
        approval?.resume(returning: allowed)
        approval = nil
    }

    func retry(tools: FlowcyToolsState, cloud: MobileCloudState) {
        guard canRetry, !isStreaming, accountID != nil, canSubmit() else { return }
        // Resume the rejected model step with its existing tool results and user message.
        // Completed mutations must never be replayed by resubmitting the original prompt.
        start(tools: tools, cloud: cloud)
    }

    func canSubmit(at date: Date = Date()) -> Bool {
        retryAt.map { date >= $0 } ?? true
    }

    func send(_ prompt: String, tools: FlowcyToolsState, cloud: MobileCloudState) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming, accountID != nil, canSubmit() else { return }
        performedWrite = false
        messages.append(.init(role: "user", text: prompt))
        history.append(.object(["role": .string("user"), "content": .string(prompt + "\n\nAvailable account projects: " + cloud.projects.map { "\($0.title) (project: \($0.id))" }.joined(separator: ", "))]))
        start(tools: tools, cloud: cloud)
    }

    private func start(tools: FlowcyToolsState, cloud: MobileCloudState) {
        error = nil
        canRetry = false
        retryAt = nil
        isStreaming = true
        let current = generation
        run = Task {
            defer {
                if generation == current { isStreaming = false; progress = nil; run = nil; persist() }
            }
            do {
                if !tools.isConnected {
                    progress = "Loading tools…"
                    await tools.connect()
                }
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                guard tools.isConnected else { throw tools.failure ?? FlowcyError.message(tools.error ?? "Could not load Flowcy tools. Try again.") }
                try await turn(tools: tools, cloud: cloud, current: current)
                try Task.checkCancellation()
                if generation == current { MobileHaptics.streamFinished() }
            } catch is CancellationError { }
            catch {
                guard generation == current else { return }
                if case let FlowcyError.rateLimited(_, date) = error {
                    canRetry = true
                    retryAt = date
                }
                self.error = error.localizedDescription
                if canRetry { self.error? += " Your prompt is saved; it will not be sent automatically." }
                if performedWrite && !canRetry {
                    self.error? += " A tool action was already submitted. Check its result before sending another prompt."
                }
                MobileHaptics.connectionError()
            }
        }
    }

    private func turn(tools: FlowcyToolsState, cloud: MobileCloudState, current: UUID) async throws {
        // Each model step is separated from tool execution so writes can require native consent.
        for _ in 0..<8 {
            try Task.checkCancellation()
            progress = nil
            let declared = try tools.tools.map { tool -> JSONValue in
                try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tool))
            }
            let body: JSONValue = .object(["messages": .array(history), "tools": .array(declared)])
            let (bytes, response) = try await api.request(path: "agent/chat", body: body)
            guard response.value(forHTTPHeaderField: "Content-Type")?.contains("application/x-ndjson") == true else { throw FlowcyError.protocolError }
            messages.append(.init(role: "assistant", text: ""))
            let index = messages.count - 1
            var calls: [(String, FlowcyTool, JSONValue)] = []
            var finished = false
            var text = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                if line.isEmpty { continue }
                guard line.utf8.count <= 1_000_000 else { throw FlowcyError.protocolError }
                let event = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
                switch event["type"]?.stringValue {
                case "text":
                    let delta = event["text"]?.stringValue ?? ""
                    text += delta
                    guard text.utf8.count <= 1_000_000 else { throw FlowcyError.protocolError }
                    messages[index].text = text
                case "tool-call":
                    guard let name = event["name"]?.stringValue, let id = event["id"]?.stringValue,
                          let tool = tools.tools.first(where: { $0.name == name }), let arguments = event["arguments"] else { throw FlowcyError.protocolError }
                    calls.append((id, tool, arguments))
                    var input: [String: JSONValue] = ["arguments": arguments]
                    if case .object(let object) = arguments { input = object }
                    if messages[index].toolCalls == nil { messages[index].toolCalls = [] }
                    messages[index].toolCalls?.append(ToolCall(id: id, name: name, input: input))
                case "finish": finished = true
                case "error": throw FlowcyError.message("The agent could not complete its response. Try again.")
                default: throw FlowcyError.protocolError
                }
            }
            guard finished else { throw FlowcyError.message("The reply was interrupted. Retry to continue.") }
            var content: [JSONValue] = []
            if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
            for (id, tool, arguments) in calls {
                content.append(.object(["type": .string("tool-call"), "toolCallId": .string(id), "toolName": .string(tool.name), "input": arguments]))
            }
            let assistant: JSONValue = .object(["role": .string("assistant"), "content": .array(content)])
            if calls.isEmpty { if !content.isEmpty { history.append(assistant) }; return }
            var results: [JSONValue] = []
            for (id, tool, arguments) in calls {
                try Task.checkCancellation()
                let allowed: Bool
                if tool.isReadOnly { allowed = true }
                else {
                    MobileHaptics.attentionNeeded()
                    allowed = await withCheckedContinuation { continuation in
                        approval = continuation
                        pendingTool = FlowcyPendingTool(id: id, tool: tool, arguments: arguments)
                    }
                }
                try Task.checkCancellation()
                progress = "Running \(tool.name)…"
                let result: JSONValue
                if allowed {
                    do {
                        if !tool.isReadOnly { performedWrite = true }
                        result = try await tools.call(tool, arguments: arguments)
                        if !tool.isReadOnly && result["isError"]?.boolValue != true {
                            await cloud.refresh()
                            for project in cloud.projects { try? await cloud.loadBoard(project.id) }
                            NotificationCenter.default.post(name: .flowcyDashboardChanged, object: nil)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { result = .object(["isError": .bool(true), "content": .array([.object(["type": .string("text"), "text": .string(error.localizedDescription)])])]) }
                } else { result = .object(["isError": .bool(true), "message": .string("The user denied this tool call.")]) }
                guard generation == current else { throw CancellationError() }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let output = String(decoding: try encoder.encode(result), as: UTF8.self)
                if let callIndex = messages[index].toolCalls?.firstIndex(where: { $0.id == id }) {
                    messages[index].toolCalls?[callIndex].result = output
                    messages[index].toolCalls?[callIndex].isError = result["isError"]?.boolValue == true
                }
                results.append(.object(["type": .string("tool-result"), "toolCallId": .string(id), "toolName": .string(tool.name), "output": .object(["type": .string("json"), "value": result])]))
            }
            history.append(assistant)
            history.append(.object(["role": .string("tool"), "content": .array(results)]))
            persist()
        }
        throw FlowcyError.message("The agent reached its tool limit. Send another prompt to continue.")
    }

    private func persist() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Saved(messages: messages, history: history))
            guard data.count <= 4_000_000 else { error = "This chat is too large to save. Start a new chat."; return }
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        } catch { self.error = "Could not save this conversation on the device." }
    }
}

extension Notification.Name { static let flowcyDashboardChanged = Notification.Name("flowcyDashboardChanged") }
