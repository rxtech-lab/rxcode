import Foundation
import enum RxAgentBridge.MCPConfigRenderer
import struct RxAgentCore.MCPServerSpec
import RxCodeCore
import Synchronization

struct PlanningTurnError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct PlanningTurn: Sendable {
    var text = ""
    var toolCalls: [ToolCall] = []
}

/// Collects both the incremental SDK protocol and the legacy CLI wire frames.
/// A completed assistant block replaces its streamed preview exactly once.
private nonisolated struct PlanningTurnBuffer {
    enum Change { case none, text, tools }

    var completed = ""
    var partial = ""
    var failure: String?
    var toolCalls: [ToolCall] = []
    private var inputBlocks: [Double: (id: String, json: String)] = [:]
    var text: String { completed + partial }

    var finalText: String {
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !answer.isEmpty { return answer }
        return toolCalls.last(where: { $0.name == "ExitPlanMode" })?.input["plan"]?.stringValue ?? ""
    }

    mutating func receive(_ event: StreamEvent) -> Change {
        switch event {
        case .textDelta(let text):
            partial += text
            return .text
        case .toolCallStarted(let id, let name):
            return recordTool(id: id, name: name)
        case .toolCallInput(let id, let input):
            return recordTool(id: id, input: input)
        case .unknown(let raw):
            return receiveFrame(raw)
        case .assistant(let message):
            var blocks: [String] = []
            var change = Change.none
            for block in message.content {
                switch block {
                case .text(let text) where !text.isEmpty: blocks.append(text)
                case .toolUse(let id, let name, let input):
                    change = recordTool(id: id, name: name, input: input)
                default: break
                }
            }
            guard !blocks.isEmpty else { return change }
            completed += blocks.joined(separator: "\n\n") + "\n\n"
            partial = ""
            return change == .tools ? .tools : .text
        case .user(let message):
            if message.isError { failure = message.content }
            guard let id = message.toolUseId, let index = toolCalls.firstIndex(where: { $0.id == id }) else { return .none }
            toolCalls[index].result = message.content
            toolCalls[index].isError = message.isError
            return .tools
        default: return .none
        }
    }

    private mutating func recordTool(id: String, name: String? = nil, input: [String: JSONValue] = [:]) -> Change {
        if let index = toolCalls.firstIndex(where: { $0.id == id }) {
            let call = toolCalls[index]
            toolCalls[index] = ToolCall(id: id, name: name ?? call.name,
                input: call.input.merging(input) { _, new in new }, result: call.result, isError: call.isError)
        } else if let name {
            toolCalls.append(ToolCall(id: id, name: name, input: input))
        } else { return .none }
        return .tools
    }

    private mutating func receiveFrame(_ raw: String) -> Change {
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: Data(raw.utf8)) else { return .none }
        if let item = object["params"]?["item"], item["type"]?.stringValue == "agentMessage" {
            switch object["method"]?.stringValue {
            case "item/started" where item["phase"]?.stringValue == "final_answer":
                completed = ""
                partial = ""
            case "item/completed":
                let block = item["text"]?.stringValue ?? partial
                if !block.isEmpty { completed += block + "\n\n" }
                partial = ""
            default: return .none
            }
            return .text
        }

        let frame = object["event"]?.objectValue ?? object
        // Claude numbers concurrent content blocks. Codex emits one unnumbered block at a time.
        let index = frame["index"]?.numberValue ?? 0
        switch frame["type"]?.stringValue {
        case "content_block_start":
            guard let block = frame["content_block"], block["type"]?.stringValue == "tool_use",
                  let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return .none }
            inputBlocks[index] = (id, "")
            return recordTool(id: id, name: name, input: block["input"]?.objectValue ?? [:])
        case "content_block_delta":
            let delta = frame["delta"]
            switch delta?["type"]?.stringValue {
            case "text_delta":
                partial += delta?["text"]?.stringValue ?? ""
                return .text
            case "input_json_delta":
                inputBlocks[index]?.json += delta?["partial_json"]?.stringValue ?? ""
                return .none
            default: return .none
            }
        case "content_block_stop":
            guard let block = inputBlocks.removeValue(forKey: index),
                  let input = try? JSONDecoder().decode([String: JSONValue].self, from: Data(block.json.utf8)) else { return .none }
            return recordTool(id: block.id, input: input)
        default: return .none
        }
    }
}

extension AppState {
    func planningText(
        model: AgentModel, prompt: String, cwd: String, inactivityTimeout: Duration = .seconds(300)
    ) async throws -> String {
        try await planningTurn(model: model, prompt: prompt, cwd: cwd, inactivityTimeout: inactivityTimeout).text
    }

    func planningTurn(
        model: AgentModel, prompt: String, cwd: String,
        inactivityTimeout: Duration = .seconds(300),
        questions: CodingPlanQuestions? = nil,
        onUpdate: @escaping @MainActor @Sendable (PlanningTurn) -> Void = { _ in }
    ) async throws -> PlanningTurn {
        let parts = model.provider == .acp ? acpSelectionParts(for: model.id) : nil
        let spec = parts.flatMap { selection in acpClients.first { $0.enabled && $0.id == selection.clientId } }
        if model.provider == .acp && spec == nil {
            throw PlanningTurnError(message: "The selected ACP client is unavailable.")
        }
        let id = UUID()
        var bridge: MCPBridgeCommand?
        if let questions, model.provider != .flowcy && model.provider != .localAgent {
            guard let port = await ideMCPServer.allocate(sessionKey: id.uuidString, capabilities: [], handler: questions) else {
                throw PlanningTurnError(message: "Could not start the debate question tool. Resume to retry this turn.")
            }
            let command = IDEMCPServer.bridgeCommand(forPort: port)
            bridge = MCPBridgeCommand(command: command.command, args: command.args)
        }
        defer {
            if bridge != nil { Task { [ideMCPServer] in await ideMCPServer.release(sessionKey: id.uuidString) } }
        }
        let servers: [RxAgentCore.MCPServerSpec] = bridge.map { [.ideBridge($0)] } ?? []
        let codexOverrides = model.provider == .codex
            ? await mcp.codexConfigOverrides(projectPath: cwd, disableAllServers: true)
                + MCPConfigRenderer.codexOverrides(servers: servers, toolServer: nil) + ["--disable", "plugins"]
            : []
        let askUser: BackendSendRequest.AskUser? = if let questions {
            { arguments in try await questions.ask(arguments) }
        } else { nil }
        let request = BackendSendRequest(
            streamId: id, prompt: prompt, cwd: cwd, sessionId: nil,
            model: parts.map { $0.model.isEmpty ? nil : $0.model } ?? model.id,
            permissionMode: .plan, planMode: true, isEphemeral: true,
            mcpClaudeConfigPath: model.provider == .claudeCode && bridge != nil
                ? MCPConfigRenderer.claudeConfigJSON(servers: servers, toolServer: nil) : nil,
            mcpCodexOverrides: codexOverrides,
            acpMCPServers: model.provider == .acp
                ? MCPConfigRenderer.acpServers(servers: servers, toolServer: nil, supportsHTTP: false, supportsSSE: false).map(AppJSON.init) : [],
            acpSpec: spec, clientSessionKey: id.uuidString, ideBridgeCommand: bridge, askUser: askUser
        )
        return try await Self.readPlanningTurn(request, backend: backend(for: model.provider),
                                               inactivityTimeout: inactivityTimeout, questions: questions, onUpdate: onUpdate)
    }

    private nonisolated static func readPlanningTurn(
        _ request: BackendSendRequest, backend: any AgentBackend,
        inactivityTimeout: Duration, questions: CodingPlanQuestions?,
        onUpdate: @escaping @MainActor @Sendable (PlanningTurn) -> Void
    ) async throws -> PlanningTurn {
        let id = request.streamId
        let stream = await backend.send(request)
        let clock = ContinuousClock()
        let idleDeadline = Mutex(clock.now.advanced(by: inactivityTimeout))
        do {
            let turn = try await withThrowingTaskGroup(of: PlanningTurn.self) { group in
                group.addTask {
                    var buffer = PlanningTurnBuffer()
                    var publishAt = clock.now
                    for await event in stream {
                        try Task.checkCancellation()
                        // Reasoning and tool activity also keep the turn alive between text updates.
                        idleDeadline.withLock { $0 = clock.now.advanced(by: inactivityTimeout) }
                        if case .result(let result) = event, !result.isTaskNotification {
                            let answer = buffer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if result.isError {
                                let detail = await backend.consumeStderr(for: id) ?? buffer.failure
                                throw PlanningTurnError(message: detail ?? (answer.isEmpty ? "The agent could not finish this turn." : answer))
                            }
                            let final = buffer.finalText
                            guard !final.isEmpty else { throw PlanningTurnError(message: "The agent returned an empty response.") }
                            return PlanningTurn(text: final, toolCalls: buffer.toolCalls)
                        }
                        let change = buffer.receive(event)
                        if change == .tools || (change == .text && clock.now >= publishAt) {
                            await onUpdate(PlanningTurn(text: buffer.text, toolCalls: buffer.toolCalls))
                            publishAt = clock.now.advanced(by: .milliseconds(75))
                        }
                    }
                    try Task.checkCancellation()
                    let detail = await backend.consumeStderr(for: id) ?? buffer.failure
                    throw PlanningTurnError(message: detail ?? "The agent disconnected before finishing its turn.")
                }
                group.addTask {
                    while true {
                        var deadline = idleDeadline.withLock { $0 }
                        if let questions {
                            deadline = await questions.inactivityDeadline(streamDeadline: deadline, timeout: inactivityTimeout)
                        }
                        guard clock.now < deadline else {
                            let duration = inactivityTimeout.formatted(.units(width: .wide))
                            throw PlanningTurnError(message: "The agent sent no updates for \(duration).")
                        }
                        try await clock.sleep(until: deadline)
                    }
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            await backend.finalize(streamId: id)
            try Task.checkCancellation()
            return turn
        } catch {
            await backend.cancel(streamId: id)
            await backend.finalize(streamId: id)
            throw error
        }
    }
}
