import CoreFoundation
import Foundation
import MCP
import Network
import RxCodeCore
import os

extension IDEMCPServer {
    // MARK: - Helpers

    static func toolDescriptor(_ tool: IDETool) -> [String: Any] {
        var descriptor: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": tool.inputSchema.toAny() ?? [:]
        ]
        if let annotations = toolAnnotations(for: tool) {
            descriptor["annotations"] = annotations
        }
        return descriptor
    }

    static func mcpTool(_ tool: IDETool) throws -> MCP.Tool {
        let annotations: MCP.Tool.Annotations
        if let hints = toolAnnotations(for: tool) {
            annotations = .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: hints["idempotentHint"] as? Bool,
                openWorldHint: hints["openWorldHint"] as? Bool ?? false
            )
        } else {
            annotations = nil
        }
        return try MCP.Tool(
            name: tool.name,
            description: tool.description,
            inputSchema: MCP.Value(tool.inputSchema),
            annotations: annotations
        )
    }

    private static func toolAnnotations(for tool: IDETool) -> [String: Any]? {
        if tool.name == IDEToolRegistry.askUser.name {
            return ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
        }
        let readOnlyTools: Set<String> = [
            "ide__flowcy_catalog",
            "ide__get_ci_status",
            "ide__search_docs",
            "ide__get_running_jobs",
            "ide__get_job_output",
            "ide__get_projects",
            "ide__get_stories",
            "ide__get_tasks",
            "ide__list_agent_models",
            JSONUITool.ideName,
            "ide__get_task_status",
            "ide__list_coding_plans",
            "ide__list_coding_plan_versions",
            "ide__get_coding_plan_version",
            "ide__get_threads",
            "ide__get_thread_messages",
            "ide__get_thread_detail",
            "ide__memory_search",
            "memory_search",
            "ide__get_usage",
            "ide__get_integration_usage",
            "ide__briefing_list",
            "ide__briefing_get",
            "ide__project_briefings",
            "ide__project_briefing_get",
            "ide__skill_get",
        ]

        guard readOnlyTools.contains(tool.name) else { return nil }
        return [
            "readOnlyHint": true,
            "destructiveHint": false,
            "idempotentHint": true,
            "openWorldHint": ["ide__get_ci_status", "ide__search_docs", "ide__skill_get"].contains(tool.name),
        ]
    }

    /// Wrap a handler's `JSONValue` result in the MCP tool-call response
    /// envelope: a `content` array with `text` blocks. Handlers may either
    /// pass a string scalar (auto-wrapped) or the full object form.
    static func wrapToolResult(_ value: JSONValue) -> [String: Any] {
        if case .object(let dict) = value, dict["content"] != nil {
            return value.toAny() as? [String: Any] ?? [:]
        }
        let text: String
        switch value {
        case .string(let s): text = s
        case .null: text = ""
        default:
            if
                let data = try? JSONSerialization.data(
                    withJSONObject: value.toAny() ?? [:],
                    options: [.prettyPrinted, .sortedKeys]
                ),
                let s = String(data: data, encoding: .utf8)
            {
                text = s
            } else {
                text = "\(value)"
            }
        }
        return [
            "content": [
                ["type": "text", "text": text]
            ]
        ]
    }

    static func mcpCallResult(_ value: JSONValue) throws -> MCP.CallTool.Result {
        let wrapped = wrapToolResult(value)
        let data = try JSONSerialization.data(withJSONObject: wrapped)
        return try JSONDecoder().decode(MCP.CallTool.Result.self, from: data)
    }

    static func errorCode(for error: IDEToolError) -> Int {
        switch error {
        case .unknownTool:        return -32601
        case .invalidArguments:   return -32602
        case .notSupported:       return -32004
        case .handlerFailed:      return -32603
        }
    }

    static func errorMessage(for error: IDEToolError) -> String {
        switch error {
        case .unknownTool(let n):      return "Unknown tool: \(n)"
        case .invalidArguments(let m): return "Invalid arguments: \(m)"
        case .notSupported(let m):     return "Not supported: \(m)"
        case .handlerFailed(let m):    return m
        }
    }
}
