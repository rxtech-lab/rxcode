import Foundation
import RxCodeCore

extension AppState {
    func loadMCPApp(for toolCall: ToolCall, projectPath: String?) async throws -> MCPAppResource? {
        let records = try await mcp.globalRecords()
        // Match against configured names, including names that themselves contain '__'.
        for record in records.sorted(by: { $0.name.count > $1.name.count }) where record.isEnabled(for: projectPath) {
            let prefix = "mcp__\(record.name)__"
            let toolName: String?
            if toolCall.name.hasPrefix(prefix) {
                toolName = String(toolCall.name.dropFirst(prefix.count))
            } else if toolCall.input["server"]?.stringValue == record.name {
                toolName = toolCall.input["tool"]?.stringValue ?? toolCall.input["name"]?.stringValue
            } else {
                toolName = nil
            }
            if let toolName, !toolName.isEmpty {
                let configured = try await mcp.authenticatedDetail(name: record.name, projectPath: projectPath)
                let environment = await claude.resolvedEnvironment().merging(configured.env) { _, value in value }
                let detail = MCPServerDetail(name: configured.name, scope: configured.scope, transport: configured.transport,
                    url: configured.url, command: configured.command, args: configured.args, env: environment,
                    headers: configured.headers, projectPath: projectPath)
                return try await MCPAppConnection(detail: detail).load(toolName: toolName)
            }
        }
        return nil
    }
}
