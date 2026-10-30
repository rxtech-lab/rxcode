import Foundation
import RxCodeCore

/// Which tools of a server advertise an App, so chat rows for App-less tools don't
/// open a fresh MCP connection every time they render.
@MainActor
private enum MCPAppToolCache {
    static let lifetime: TimeInterval = 600
    static var entries: [String: (created: Date, names: Task<Set<String>, Error>)] = [:]
}

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
                guard try await mcpAppToolNames(server: record.name, projectPath: projectPath).contains(toolName) else {
                    return nil
                }
                return try await MCPAppConnection(detail: mcpAppServerDetail(name: record.name, projectPath: projectPath))
                    .load(toolName: toolName)
            }
        }
        return nil
    }

    private func mcpAppToolNames(server: String, projectPath: String?) async throws -> Set<String> {
        let key = "\(server)\u{0}\(projectPath ?? "")"
        if let entry = MCPAppToolCache.entries[key], Date().timeIntervalSince(entry.created) < MCPAppToolCache.lifetime {
            return try await entry.names.value
        }
        let task = Task { @MainActor in
            try await MCPAppConnection(detail: mcpAppServerDetail(name: server, projectPath: projectPath)).appToolNames()
        }
        MCPAppToolCache.entries[key] = (Date(), task)
        do {
            return try await task.value
        } catch {
            // Don't remember failures (offline server, expired sign-in); retry on the next render.
            MCPAppToolCache.entries[key] = nil
            throw error
        }
    }

    private func mcpAppServerDetail(name: String, projectPath: String?) async throws -> MCPServerDetail {
        let configured = try await mcp.authenticatedDetail(name: name, projectPath: projectPath)
        let environment = await claude.resolvedEnvironment().merging(configured.env) { _, value in value }
        return MCPServerDetail(name: configured.name, scope: configured.scope, transport: configured.transport,
            url: configured.url, command: configured.command, args: configured.args, env: environment,
            headers: configured.headers, projectPath: projectPath)
    }
}
