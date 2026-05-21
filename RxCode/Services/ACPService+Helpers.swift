import Foundation
import RxCodeCore
import os

// MARK: - File / Capability / Tool-Call Helpers

extension ACPService {

    // MARK: - File Helpers

    static func readTextFile(path: String, line: Int?, limit: Int?) throws -> String {
        let url = URL(fileURLWithPath: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        if line == nil && limit == nil { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let start = max(0, (line ?? 1) - 1)
        let end = limit.map { min(lines.count, start + $0) } ?? lines.count
        guard start < lines.count else { return "" }
        return lines[start..<end].joined(separator: "\n")
    }

    static func writeTextFile(path: String, content: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Capability Helpers

    func agentSupportsLoadSession(_ initResult: JSONValue) -> Bool {
        initResult.objectValue?["agentCapabilities"]?.objectValue?["loadSession"]?.boolValue ?? false
    }

    func agentSupportsMCPTransport(_ transport: String, initResult: JSONValue) -> Bool {
        guard transport == "http" || transport == "sse" else { return true }
        return initResult
            .objectValue?["agentCapabilities"]?
            .objectValue?["mcpCapabilities"]?
            .objectValue?[transport]?
            .boolValue ?? false
    }

    func supportedMCPServers(_ servers: [JSONValue], initResult: JSONValue) -> [JSONValue] {
        let mcpCaps = initResult.objectValue?["agentCapabilities"]?.objectValue?["mcpCapabilities"]
        logger.info("[ACP-MCP] agent advertised mcpCapabilities=\(mcpCaps?.shortDescription ?? "<nil>", privacy: .public) (http=\(mcpCaps?.objectValue?["http"]?.boolValue == true) sse=\(mcpCaps?.objectValue?["sse"]?.boolValue == true))")

        var supported: [JSONValue] = []
        var dropped: [String] = []

        for server in servers {
            let obj = server.objectValue
            let transport = obj?["type"]?.stringValue ?? "stdio"
            let name = obj?["name"]?.stringValue ?? "<unnamed>"
            if agentSupportsMCPTransport(transport, initResult: initResult) {
                logger.info("[ACP-MCP] passing entry name=\(name, privacy: .public) transport=\(transport, privacy: .public)")
                supported.append(server)
            } else {
                logger.info("[ACP-MCP] dropping entry name=\(name, privacy: .public) transport=\(transport, privacy: .public) — agent doesn't advertise capability")
                dropped.append("\(name):\(transport)")
            }
        }

        if !dropped.isEmpty {
            logger.info("[ACP-MCP] dropping unsupported MCP transports: \(dropped.joined(separator: ", "), privacy: .public)")
        }
        logger.info("[ACP-MCP] passing \(supported.count, privacy: .public)/\(servers.count, privacy: .public) mcpServers after initialize capability check")
        return supported
    }

    /// Scans a `session/new` (or `session/load`) response for the first
    /// `SessionConfigOption` with `category: "model"` and `type: "select"`,
    /// flattening grouped options.
    static func parseModelConfig(from result: JSONValue) -> ACPModelConfig? {
        guard let configOptions = result.objectValue?["configOptions"]?.arrayValue else { return nil }
        for option in configOptions {
            guard let obj = option.objectValue,
                  obj["category"]?.stringValue == "model",
                  obj["type"]?.stringValue == "select",
                  let configId = obj["id"]?.stringValue,
                  let opts = obj["options"]?.arrayValue
            else { continue }

            var flattened: [ACPModelOption] = []
            for entry in opts {
                guard let entryObj = entry.objectValue else { continue }
                if let groupOpts = entryObj["options"]?.arrayValue {
                    for groupEntry in groupOpts {
                        if let parsed = parseSelectOption(groupEntry) {
                            flattened.append(parsed)
                        }
                    }
                } else if let parsed = parseSelectOption(entry) {
                    flattened.append(parsed)
                }
            }
            guard !flattened.isEmpty else { continue }
            return ACPModelConfig(
                configId: configId,
                currentValue: obj["currentValue"]?.stringValue,
                options: flattened
            )
        }
        return nil
    }

    // MARK: - Tool Call Normalization
    //
    // ACP `tool_call` notifications expose two views of a tool invocation:
    // a machine-readable `kind` ("edit", "execute", "read", …) and a
    // human-readable `title`. The agent's `rawInput` is opaque (each agent
    // chooses its own schema), but the optional `content` array surfaces
    // structured `diff` entries (`{path, oldText, newText}`) that we can
    // translate into the Claude-shaped `Edit`/`Write`/`MultiEdit` input keys
    // the rest of RxCode (sidebar persistence, diff renderer, plan card)
    // already understands.

    struct NormalizedToolCall {
        let name: String
        let input: [String: JSONValue]
    }

    /// Extracts `{type: "diff", path, oldText, newText}` entries from a
    /// session/update payload's `content` array. Returns `[]` for non-edit
    /// kinds or absent content.
    static func diffEntries(in update: [String: JSONValue]) -> [(path: String, oldText: String?, newText: String)] {
        guard let content = update["content"]?.arrayValue else { return [] }
        var out: [(path: String, oldText: String?, newText: String)] = []
        for entry in content {
            guard let obj = entry.objectValue,
                  obj["type"]?.stringValue == "diff",
                  let path = obj["path"]?.stringValue,
                  let newText = obj["newText"]?.stringValue
            else { continue }
            let oldText = obj["oldText"]?.stringValue
            out.append((path: path, oldText: oldText, newText: newText))
        }
        return out
    }

    /// Translates an ACP tool_call payload into a Claude-shaped (name, input).
    /// Edit-kind calls with diff content become `Edit`/`Write`/`MultiEdit` so
    /// `ChatMessage.fileEditHunks` and `editedFilePath` can extract the path
    /// and hunks for sidebar persistence. Other kinds fall back to the agent's
    /// title + rawInput unchanged.
    static func normalizeToolCall(
        kind: String?,
        title: String,
        update: [String: JSONValue],
        rawInput: [String: JSONValue]
    ) -> NormalizedToolCall {
        let normalizedKind = (kind ?? "").lowercased()
        let diffs = diffEntries(in: update)
        if normalizedKind == "edit" || !diffs.isEmpty {
            if !diffs.isEmpty {
                if diffs.count == 1 {
                    let only = diffs[0]
                    let oldText = only.oldText ?? ""
                    if oldText.isEmpty {
                        return NormalizedToolCall(
                            name: "Write",
                            input: [
                                "file_path": .string(only.path),
                                "content": .string(only.newText)
                            ]
                        )
                    }
                    return NormalizedToolCall(
                        name: "Edit",
                        input: [
                            "file_path": .string(only.path),
                            "old_string": .string(oldText),
                            "new_string": .string(only.newText)
                        ]
                    )
                }
                let primaryPath = diffs.first!.path
                let edits: [JSONValue] = diffs.filter { $0.path == primaryPath }.map { d in
                    .object([
                        "old_string": .string(d.oldText ?? ""),
                        "new_string": .string(d.newText)
                    ])
                }
                return NormalizedToolCall(
                    name: "MultiEdit",
                    input: [
                        "file_path": .string(primaryPath),
                        "edits": .array(edits)
                    ]
                )
            }
            var input = rawInput
            if input["file_path"] == nil,
               let path = (update["locations"]?.arrayValue?.first?.objectValue?["path"]?.stringValue) {
                input["file_path"] = .string(path)
            }
            return NormalizedToolCall(name: "Edit", input: input)
        }

        return NormalizedToolCall(name: title, input: rawInput)
    }

    /// Wraps a text chunk in the same raw-event shape Claude's CLI emits, so
    /// `AppState.handlePartialEvent` accumulates it into `state.textDeltaBuffer`.
    static func textDeltaFrame(_ text: String) -> String {
        let payload: [String: Any] = [
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": text]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    static func thinkingDeltaFrame(_ text: String) -> String {
        let payload: [String: Any] = [
            "type": "content_block_delta",
            "delta": ["type": "thinking_delta", "thinking": text]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    static func parseSelectOption(_ value: JSONValue) -> ACPModelOption? {
        guard let obj = value.objectValue,
              let val = obj["value"]?.stringValue,
              let name = obj["name"]?.stringValue
        else { return nil }
        return ACPModelOption(
            value: val,
            name: name,
            description: obj["description"]?.stringValue
        )
    }

    static func modelListDescription(_ options: [ACPModelOption]) -> String {
        options.map { option in
            option.name == option.value ? option.value : "\(option.value) (\(option.name))"
        }.joined(separator: ", ")
    }
}

// MARK: - JSONValue Conveniences

extension JSONValue {
    nonisolated var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    nonisolated var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    nonisolated var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    nonisolated var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    nonisolated var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }
    nonisolated var shortDescription: String {
        switch self {
        case .object(let o): return "object(\(o.count) keys)"
        case .array(let a): return "array(\(a.count))"
        case .string(let s): return s.prefix(80).description
        case .number(let n): return "\(n)"
        case .bool(let b): return "\(b)"
        case .null: return "null"
        }
    }
}

// MARK: - AgentBackend Conformance

extension ACPService: AgentBackend {
    nonisolated var provider: AgentProvider { .acp }
    nonisolated var staticCapabilities: CapabilitySet { AgentProvider.acp.staticCapabilities }

    func send(_ request: BackendSendRequest) -> AsyncStream<StreamEvent> {
        guard let spec = request.acpSpec else {
            return AsyncStream<StreamEvent> { c in
                c.yield(.user(UserMessage(
                    toolUseId: nil,
                    content: "No ACP client configured. Add one in Settings → ACP Clients.",
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
            sessionId: request.sessionId,
            model: request.model,
            spec: spec,
            permissionMode: request.permissionMode,
            clientSessionKey: request.clientSessionKey,
            mcpServers: request.acpMCPServers
        )
    }
}
