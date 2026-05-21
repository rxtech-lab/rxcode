import Foundation
import RxCodeCore
import os

// MARK: - JSON-RPC Framing, Read Loop & Agent Messages

extension ACPService {

    // MARK: - JSON-RPC Framing

    func sendRequest(key: String, method: String, params: [String: JSONValue])
        async throws -> JSONValue
    {
        guard sessions[key] != nil else { throw ACPError.streamClosed }

        let id = nextRequestId(key: key)
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": .object(params)
        ]
        try writeFrame(key: key, frame: .object(frame))
        logger.info("[ACP] → \(method, privacy: .public) id=\(id) key=\(key, privacy: .public)")

        return try await withCheckedThrowingContinuation { cont in
            mutateSession(key) { $0.pending[id] = cont }
        }
    }

    func sendResult(key: String, id: JSONValue, result: JSONValue) {
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result
        ]
        try? writeFrame(key: key, frame: .object(frame))
    }

    func sendError(key: String, id: JSONValue, code: Int, message: String) {
        let frame: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message)
            ])
        ]
        try? writeFrame(key: key, frame: .object(frame))
    }

    func writeFrame(key: String, frame: JSONValue) throws {
        guard let entry = sessions[key] else { throw ACPError.streamClosed }
        let data = try JSONEncoder().encode(frame)
        var line = data
        line.append(0x0A)
        try entry.stdin.write(contentsOf: line)
    }

    func nextRequestId(key: String) -> Int {
        var id = 0
        mutateSession(key) { entry in
            id = entry.nextId
            entry.nextId += 1
        }
        return id
    }

    func mutateSession(_ key: String, _ mutate: (inout SessionEntry) -> Void) {
        guard var entry = sessions[key] else { return }
        mutate(&entry)
        sessions[key] = entry
    }

    // MARK: - Read Loop
    //
    // We deliberately avoid `FileHandle.bytes.lines`: in practice that
    // AsyncSequence does not reliably drain Pipe-backed stdout on Darwin —
    // bytes can sit indefinitely until the writer closes the pipe. Instead we
    // use `readabilityHandler`, which is GCD-backed and fires as soon as data
    // arrives, and split into newline-delimited frames ourselves.

    static func spawnStdoutReader(
        key: String,
        stdout: FileHandle,
        service: ACPService
    ) -> Task<Void, Never> {
        let chunkStream = AsyncStream<Data> { continuation in
            stdout.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                    handle.readabilityHandler = nil
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in
                stdout.readabilityHandler = nil
            }
        }

        return Task.detached { [weak service] in
            await service?.logReaderStarted(key: key)
            var buffer = Data()
            for await chunk in chunkStream {
                if Task.isCancelled {
                    await service?.logReaderCancelled(key: key)
                    stdout.readabilityHandler = nil
                    return
                }
                buffer.append(chunk)
                while let nlIdx = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nlIdx)
                    buffer.removeSubrange(buffer.startIndex...nlIdx)
                    guard !lineData.isEmpty,
                          let line = String(data: lineData, encoding: .utf8) else { continue }
                    await service?.deliverStdoutLine(key: key, line: line, data: lineData)
                }
            }
            await service?.logReaderEOF(key: key)
        }
    }

    func logReaderStarted(key: String) {
        logger.info("[ACP] read loop started for key=\(key, privacy: .public)")
    }
    func logReaderCancelled(key: String) {
        logger.info("[ACP] read loop cancelled for key=\(key, privacy: .public)")
    }
    func logReaderEOF(key: String) {
        logger.info("[ACP] read loop EOF for key=\(key, privacy: .public)")
    }
    func logReaderError(error: Error) {
        logger.warning("[ACP] read loop error: \(error.localizedDescription, privacy: .public)")
    }

    func deliverStdoutLine(key: String, line: String, data: Data) async {
        // Resolve the latest canonical key in case the entry has been
        // re-keyed (bootstrap key → agent sessionId).
        let resolved = aliasToCanonical[key] ?? key
        logger.info("[ACP][stdout] \(line.prefix(400), privacy: .public)")
        await handleIncoming(key: resolved, data: data)
    }

    func handleIncoming(key: String, data: Data) async {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            logger.warning("[ACP] decode failed: \(String(data: data, encoding: .utf8) ?? "<binary>", privacy: .public)")
            return
        }
        guard let obj = value.objectValue else { return }

        // Response (has "id" and "result"/"error", no "method").
        if obj["method"] == nil, let idVal = obj["id"], let idInt = idVal.intValue {
            resolveResponse(key: key, id: idInt, body: obj)
            return
        }

        // Request or notification (has "method").
        guard let method = obj["method"]?.stringValue else { return }
        let params = obj["params"] ?? .null

        if let idVal = obj["id"] {
            await handleAgentRequest(key: key, id: idVal, method: method, params: params)
        } else {
            handleAgentNotification(key: key, method: method, params: params)
        }
    }

    func resolveResponse(key: String, id: Int, body: [String: JSONValue]) {
        var cont: CheckedContinuation<JSONValue, Error>?
        mutateSession(key) { entry in
            cont = entry.pending.removeValue(forKey: id)
        }
        guard let cont else {
            logger.warning("[ACP] ← response id=\(id) had no pending continuation key=\(key, privacy: .public)")
            return
        }
        if let err = body["error"]?.objectValue {
            let msg = err["message"]?.stringValue ?? "ACP error"
            let code = err["code"]?.intValue ?? -1
            logger.error("[ACP] ← error id=\(id) code=\(code) msg=\(msg, privacy: .public)")
            cont.resume(throwing: ACPError.agentError(code: code, message: msg))
        } else {
            let result = body["result"] ?? .null
            logger.info("[ACP] ← ok id=\(id) result=\(result.shortDescription, privacy: .public)")
            cont.resume(returning: result)
        }
    }

    // MARK: - Agent Notifications

    func handleAgentNotification(key: String, method: String, params: JSONValue) {
        switch method {
        case "session/update":
            guard sessions[key]?.acceptingUpdates == true else {
                let kind = params.objectValue?["update"]?.objectValue?["sessionUpdate"]?.stringValue ?? "<unknown>"
                logger.info("[ACP] ⟵ pre-prompt session/update dropped kind=\(kind, privacy: .public)")
                return
            }
            handleSessionUpdate(key: key, params: params)
        default:
            logger.warning("[ACP] ⟵ unknown notification: \(method, privacy: .public)")
        }
    }

    func handleSessionUpdate(key: String, params: JSONValue) {
        guard let p = params.objectValue,
              let update = p["update"]?.objectValue,
              let kind = update["sessionUpdate"]?.stringValue,
              let continuation = sessions[key]?.continuation else {
            logger.warning("[ACP] session/update missing fields or no continuation key=\(key, privacy: .public)")
            return
        }

        switch kind {
        case "agent_message_chunk":
            if let text = update["content"]?.objectValue?["text"]?.stringValue {
                logger.info("[ACP] ⟵ agent_message_chunk len=\(text.count)")
                continuation.yield(.unknown(Self.textDeltaFrame(text)))
            } else {
                logger.warning("[ACP] agent_message_chunk had no text content")
            }

        case "agent_thought_chunk":
            if let text = update["content"]?.objectValue?["text"]?.stringValue {
                logger.info("[ACP] ⟵ agent_thought_chunk len=\(text.count)")
                continuation.yield(.unknown(Self.thinkingDeltaFrame(text)))
            }

        case "plan":
            let entries = update["entries"]?.arrayValue?.count ?? 0
            logger.info("[ACP] ⟵ plan entries=\(entries)")
            handlePlanUpdate(key: key, update: update, continuation: continuation)

        case "tool_call":
            handleToolCall(key: key, update: update, continuation: continuation)

        case "tool_call_update":
            handleToolCallUpdate(key: key, update: update, continuation: continuation)

        default:
            logger.warning("[ACP] ⟵ unhandled sessionUpdate kind: \(kind, privacy: .public)")
        }
    }

    func handlePlanUpdate(key: String, update: [String: JSONValue],
                          continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let entries = update["entries"]?.arrayValue else { return }

        var markdown = "# Plan\n\n"
        for entry in entries {
            guard let obj = entry.objectValue else { continue }
            let status = obj["status"]?.stringValue ?? "pending"
            let content = obj["content"]?.stringValue ?? ""
            let mark: String
            switch status {
            case "completed": mark = "- [x] "
            case "in_progress": mark = "- [~] "
            default: mark = "- [ ] "
            }
            markdown += "\(mark)\(content)\n"
        }

        let planId = sessions[key]?.planSyntheticId ?? "acp-plan"
        continuation.yield(.assistant(AssistantMessage(
            role: "assistant",
            content: [.toolUse(
                id: planId,
                name: "ExitPlanMode",
                input: ["plan": .string(markdown)]
            )]
        )))
        mutateSession(key) { $0.planEmitted = true }
    }

    func handleToolCall(key: String, update: [String: JSONValue],
                        continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let toolCallId = update["toolCallId"]?.stringValue else {
            logger.warning("[ACP] tool_call missing toolCallId")
            return
        }
        let title = update["title"]?.stringValue ?? update["kind"]?.stringValue ?? "tool"
        let kind = update["kind"]?.stringValue
        let rawInput = update["rawInput"]?.objectValue ?? [:]
        let normalized = Self.normalizeToolCall(kind: kind, title: title, update: update, rawInput: rawInput)
        let mcpTag = (normalized.name.contains("context7") || normalized.name.contains("mcp_") || title.contains("MCP")) ? " [MCP]" : ""
        logger.info("[ACP] ⟵ tool_call\(mcpTag, privacy: .public) id=\(toolCallId, privacy: .public) name=\(normalized.name, privacy: .public) title=\(title, privacy: .public) kind=\(kind ?? "<nil>", privacy: .public) inputKeys=[\(normalized.input.keys.sorted().joined(separator: ","), privacy: .public)]")

        mutateSession(key) { $0.liveToolCalls.insert(toolCallId) }

        continuation.yield(.assistant(AssistantMessage(
            role: "assistant",
            content: [.toolUse(id: toolCallId, name: normalized.name, input: normalized.input)]
        )))
    }

    func handleToolCallUpdate(key: String, update: [String: JSONValue],
                              continuation: AsyncStream<StreamEvent>.Continuation) {
        guard let toolCallId = update["toolCallId"]?.stringValue else {
            logger.warning("[ACP] tool_call_update missing toolCallId")
            return
        }
        let status = update["status"]?.stringValue ?? "completed"
        logger.info("[ACP] ⟵ tool_call_update id=\(toolCallId, privacy: .public) status=\(status, privacy: .public)")

        // If the update carries diff content (ACP allows the agent to attach
        // diffs on either tool_call or tool_call_update), re-emit a toolUse
        // with the merged input so AppState can persist the file edit when the
        // result lands. AppState merges by toolCallId, so this patches the
        // existing block in place rather than appending a duplicate.
        let diffEntries = Self.diffEntries(in: update)
        if !diffEntries.isEmpty {
            let kind = update["kind"]?.stringValue
            let title = update["title"]?.stringValue ?? kind ?? "tool"
            let rawInput = update["rawInput"]?.objectValue ?? [:]
            let normalized = Self.normalizeToolCall(kind: kind ?? "edit", title: title, update: update, rawInput: rawInput)
            logger.info("[ACP] ⟵ tool_call_update id=\(toolCallId, privacy: .public) carrying diffs=\(diffEntries.count) → patching toolUse name=\(normalized.name, privacy: .public)")
            continuation.yield(.assistant(AssistantMessage(
                role: "assistant",
                content: [.toolUse(id: toolCallId, name: normalized.name, input: normalized.input)]
            )))
        }

        // Compose tool result text from rawOutput or content[]
        var resultText = ""
        if let raw = update["rawOutput"] {
            if let s = raw.stringValue { resultText = s }
            else if let data = try? JSONEncoder().encode(raw),
                    let s = String(data: data, encoding: .utf8) { resultText = s }
        } else if let content = update["content"]?.arrayValue {
            resultText = content.compactMap { entry -> String? in
                guard let obj = entry.objectValue else { return nil }
                if obj["type"]?.stringValue == "content",
                   let inner = obj["content"]?.objectValue,
                   inner["type"]?.stringValue == "text" {
                    return inner["text"]?.stringValue
                }
                return obj["text"]?.stringValue
            }.joined(separator: "\n")
        }

        let isError = status == "failed"
        continuation.yield(.user(UserMessage(
            toolUseId: toolCallId,
            content: resultText.isEmpty ? (isError ? "Tool failed" : "Done") : resultText,
            isError: isError
        )))
    }

    // MARK: - Agent Requests (server-initiated)

    func handleAgentRequest(key: String, id: JSONValue, method: String, params: JSONValue) async {
        logger.info("[ACP] ⟵ agent-request \(method, privacy: .public) key=\(key, privacy: .public)")
        switch method {
        case "fs/read_text_file":
            await handleFsReadTextFile(key: key, id: id, params: params)
        case "fs/write_text_file":
            await handleFsWriteTextFile(key: key, id: id, params: params)
        case "session/request_permission":
            await handleSessionRequestPermission(key: key, id: id, params: params)
        default:
            logger.warning("[ACP] unsupported agent-request: \(method, privacy: .public)")
            sendError(key: key, id: id, code: -32601, message: "Method not supported: \(method)")
        }
    }

    func handleFsReadTextFile(key: String, id: JSONValue, params: JSONValue) async {
        guard let path = params.objectValue?["path"]?.stringValue else {
            sendError(key: key, id: id, code: -32602, message: "Missing path")
            return
        }
        do {
            let line = params.objectValue?["line"]?.intValue
            let limit = params.objectValue?["limit"]?.intValue
            let content = try Self.readTextFile(path: path, line: line, limit: limit)
            sendResult(key: key, id: id, result: .object(["content": .string(content)]))
        } catch {
            sendError(key: key, id: id, code: -32000, message: error.localizedDescription)
        }
    }

    func handleFsWriteTextFile(key: String, id: JSONValue, params: JSONValue) async {
        guard let path = params.objectValue?["path"]?.stringValue,
              let content = params.objectValue?["content"]?.stringValue else {
            sendError(key: key, id: id, code: -32602, message: "Missing path or content")
            return
        }
        do {
            try Self.writeTextFile(path: path, content: content)
            sendResult(key: key, id: id, result: .object([:]))
        } catch {
            sendError(key: key, id: id, code: -32000, message: error.localizedDescription)
        }
    }

    func handleSessionRequestPermission(key: String, id: JSONValue, params: JSONValue) async {
        guard let entry = sessions[key] else {
            logger.warning("[ACP] permission request arrived for closed session")
            sendError(key: key, id: id, code: -32000, message: "Session closed")
            return
        }
        let toolCall = params.objectValue?["toolCall"]?.objectValue ?? [:]
        let toolCallId = toolCall["toolCallId"]?.stringValue ?? UUID().uuidString
        let toolName = toolCall["title"]?.stringValue ?? toolCall["kind"]?.stringValue ?? "tool"
        let toolInput = toolCall["rawInput"]?.objectValue ?? [:]
        logger.info("[ACP] permission request tool=\(toolName, privacy: .public) id=\(toolCallId, privacy: .public)")

        guard let server = permissionServer else {
            let optionId = params.objectValue?["options"]?.arrayValue?
                .first(where: { $0.objectValue?["kind"]?.stringValue == "allow_once" })?
                .objectValue?["optionId"]?.stringValue ?? "allow"
            logger.warning("[ACP] no permission server — auto-allowing \(toolName, privacy: .public) via optionId=\(optionId, privacy: .public)")
            sendResult(key: key, id: id, result: .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionId)
                ])
            ]))
            return
        }

        let decision = await server.requestDecision(
            toolUseId: toolCallId,
            sessionId: entry.agentSessionId,
            toolName: toolName,
            toolInput: toolInput,
            mode: nil
        )
        logger.info("[ACP] permission decision tool=\(toolName, privacy: .public) decision=\(String(describing: decision), privacy: .public)")

        let options = params.objectValue?["options"]?.arrayValue ?? []
        let wantKind: String
        switch decision {
        case .allow, .allowSessionTool, .allowAlwaysCommand, .allowAndSetMode:
            wantKind = "allow_once"
        case .deny, .denyWithReason:
            wantKind = "reject_once"
        }
        let chosen = options.first { $0.objectValue?["kind"]?.stringValue == wantKind }
            ?? options.first
        let optionId = chosen?.objectValue?["optionId"]?.stringValue ?? wantKind
        logger.info("[ACP] permission reply wantKind=\(wantKind, privacy: .public) optionId=\(optionId, privacy: .public)")

        sendResult(key: key, id: id, result: .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(optionId)
            ])
        ]))
    }
}
