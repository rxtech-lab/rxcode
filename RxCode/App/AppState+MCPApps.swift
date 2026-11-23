import Foundation
import RxCodeCore

@MainActor
private enum MCPAppToolCache {
    struct Key: Hashable {
        let service: ObjectIdentifier
        let server: String
        let projectPath: String?
    }

    struct Entry {
        let id = UUID()
        let created = Date()
        let record: MCPServerRecord
        let names: Task<Set<String>, Error>
    }

    static var entries: [Key: Entry] = [:]
}

extension AppState {
    func loadMCPApp(for toolCall: ToolCall, projectPath: String?, sessionKey: String) async throws -> MCPAppResource? {
        let records = try await mcp.globalRecords()
        guard let (record, tool) = Self.mcpAppOrigin(for: toolCall, records: records),
              record.isEnabled(for: projectPath),
              try await mcpAppToolNames(record: record, projectPath: projectPath).contains(tool) else { return nil }

        let connection = try await mcp.appConnection(for: record, projectPath: projectPath)
        return try await connection.load(toolName: tool) { [weak self] action in
            guard let self else { return false }
            // Encode every displayed field together so untrusted values cannot introduce Markdown.
            let summary = JSONValue.object([
                "server": .string(record.name), "project": projectPath.map(JSONValue.string) ?? .null,
                "sourceTool": .string(tool), "toolCallID": .string(toolCall.id), "action": .string(action.actionID),
                "tool": .string(action.toolName), "arguments": .object(action.arguments)
            ]).prettyJSONString
            let indented = summary.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
            return await self.requestAgentConfirmation(.init(title: "Allow this MCP App tool call?", message: indented,
                                                            confirmLabel: "Allow"), sessionKey: sessionKey)
        }
    }

    static func mcpAppOrigin(for call: ToolCall, records: [MCPServerRecord]) -> (MCPServerRecord, String)? {
        // Resolve the wire name before inspecting enablement. A disabled longer prefix still owns its call.
        if let record = records.filter({ call.name.hasPrefix("mcp__\($0.name)__") }).max(by: { $0.name.count < $1.name.count }) {
            let tool = String(call.name.dropFirst("mcp__\(record.name)__".count))
            return tool.isEmpty ? nil : (record, tool)
        }
        // Older Codex transcripts could contain just the server name, or the generic item kind.
        guard let server = call.input["server"]?.stringValue,
              call.name == "mcpToolCall" || call.name == "mcp__\(server)",
              let record = records.first(where: { $0.name == server }),
              let tool = call.input["tool"]?.stringValue ?? call.input["name"]?.stringValue, !tool.isEmpty else { return nil }
        return (record, tool)
    }

    private func mcpAppToolNames(record: MCPServerRecord, projectPath: String?) async throws -> Set<String> {
        let key = MCPAppToolCache.Key(service: ObjectIdentifier(mcp), server: record.name, projectPath: projectPath)
        if let entry = MCPAppToolCache.entries[key], entry.record == record, Date().timeIntervalSince(entry.created) < 600 {
            return try await entry.names.value
        }
        let task = Task { [mcp] in
            try await mcp.appConnection(for: record, projectPath: projectPath).appToolNames()
        }
        let entry = MCPAppToolCache.Entry(record: record, names: task)
        MCPAppToolCache.entries[key] = entry
        do { return try await task.value } catch {
            if MCPAppToolCache.entries[key]?.id == entry.id { MCPAppToolCache.entries[key] = nil }
            throw error
        }
    }
}
