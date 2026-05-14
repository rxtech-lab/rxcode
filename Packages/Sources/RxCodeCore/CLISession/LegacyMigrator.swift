import Foundation

/// Converts legacy RxCode-owned ChatSession JSON files into CLI-compatible JSONL
/// so Claude's `--resume` can pick them up from ~/.claude/projects/{enc(cwd)}/.
public enum LegacyMigrator {

    public enum Error: Swift.Error {
        case emptySession
        case serializationFailed
    }

    private static func makeISO() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// Converts a legacy ChatSession to JSONL bytes.
    /// Each user/assistant turn becomes one or more lines:
    /// - user → one `type:"user"` line
    /// - assistant with tool calls → `type:"assistant"` + synthetic `type:"user"` (tool_results)
    /// - attachments are prepended as `[Attached: name (type)]` in the user text
    public static func toJSONL(session: ChatSession, cwd: String) throws -> Data {
        var lines: [String] = []
        var prevUUID: String? = nil
        let iso = makeISO()

        for message in session.messages {
            let blocks = message.blocks.filter { $0.text != nil || $0.toolCall != nil }
            guard !blocks.isEmpty else { continue }

            let uuid = UUID().uuidString.lowercased()
            let ts = iso.string(from: message.timestamp)

            switch message.role {
            case .user:
                var textParts: [String] = message.attachmentPaths.map {
                    "[Attached: \($0.name) (\($0.type))]"
                }
                let bodyText = blocks.compactMap(\.text).joined(separator: "\n")
                if !bodyText.isEmpty { textParts.append(bodyText) }
                let fullText = textParts.joined(separator: "\n")
                guard !fullText.isEmpty else { continue }

                let content: [[String: Any]] = [["type": "text", "text": fullText]]
                let line = userLine(uuid: uuid, parentUuid: prevUUID, promptId: uuid,
                                    content: content, ts: ts, sessionId: session.id, cwd: cwd)
                lines.append(try serialize(line))
                prevUUID = uuid

            case .assistant:
                let textParts = blocks.compactMap(\.text)
                let toolCalls = blocks.compactMap(\.toolCall)

                var contentParts: [[String: Any]] = []
                let joinedText = textParts.joined()
                if !joinedText.isEmpty {
                    contentParts.append(["type": "text", "text": joinedText])
                }
                for tc in toolCalls {
                    contentParts.append([
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.name,
                        "input": jsonValueToAny(tc.input)
                    ])
                }
                guard !contentParts.isEmpty else { continue }

                let assistantUUID = uuid
                let aLine = assistantLine(uuid: assistantUUID, parentUuid: prevUUID,
                                          content: contentParts, ts: ts,
                                          sessionId: session.id, cwd: cwd,
                                          model: session.model)
                lines.append(try serialize(aLine))

                let completed = toolCalls.filter { $0.result != nil }
                if !completed.isEmpty {
                    let resultUUID = UUID().uuidString.lowercased()
                    let resultContent: [[String: Any]] = completed.map { tc in
                        ["type": "tool_result",
                         "tool_use_id": tc.id,
                         "content": tc.result ?? "",
                         "is_error": tc.isError]
                    }
                    let rLine = userLine(uuid: resultUUID, parentUuid: assistantUUID,
                                         promptId: nil, content: resultContent,
                                         ts: ts, sessionId: session.id, cwd: cwd)
                    lines.append(try serialize(rLine))
                    prevUUID = resultUUID
                } else {
                    prevUUID = assistantUUID
                }
            }
        }

        guard !lines.isEmpty else { throw Error.emptySession }
        let joined = lines.joined(separator: "\n") + "\n"
        guard let data = joined.data(using: .utf8) else { throw Error.serializationFailed }
        return data
    }

    // MARK: - Line builders

    private static func userLine(uuid: String, parentUuid: String?, promptId: String?,
                                  content: [[String: Any]], ts: String,
                                  sessionId: String, cwd: String) -> [String: Any] {
        var d: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "parentUuid": parentUuid as Any? ?? NSNull(),
            "isSidechain": false,
            "userType": "external",
            "entrypoint": "sdk-cli",
            "gitBranch": "",
            "timestamp": ts,
            "sessionId": sessionId,
            "cwd": cwd,
            "version": "1.0.0",
            "message": ["role": "user", "content": content] as [String: Any]
        ]
        if let pid = promptId { d["promptId"] = pid }
        return d
    }

    private static func assistantLine(uuid: String, parentUuid: String?,
                                       content: [[String: Any]], ts: String,
                                       sessionId: String, cwd: String,
                                       model: String?) -> [String: Any] {
        var msg: [String: Any] = ["role": "assistant", "content": content]
        if let m = model { msg["model"] = m }
        return [
            "type": "assistant",
            "uuid": uuid,
            "parentUuid": parentUuid as Any? ?? NSNull(),
            "isSidechain": false,
            "userType": "external",
            "entrypoint": "sdk-cli",
            "gitBranch": "",
            "timestamp": ts,
            "sessionId": sessionId,
            "cwd": cwd,
            "version": "1.0.0",
            "message": msg
        ]
    }

    // MARK: - Helpers

    private static func serialize(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        guard let str = String(data: data, encoding: .utf8) else { throw Error.serializationFailed }
        return str
    }

    private static func jsonValueToAny(_ dict: [String: JSONValue]) -> [String: Any] {
        dict.mapValues { jsonValueItemToAny($0) }
    }

    private static func jsonValueItemToAny(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .number(let n):
            if n == n.rounded(), !n.isInfinite, abs(n) < Double(Int.max) { return Int(n) }
            return n
        case .bool(let b): return b
        case .object(let d): return d.mapValues { jsonValueItemToAny($0) }
        case .array(let a): return a.map { jsonValueItemToAny($0) }
        case .null: return NSNull()
        }
    }
}
